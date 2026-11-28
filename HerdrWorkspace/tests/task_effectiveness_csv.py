"""Measure a user-reported CSV import repair through the SwarmHub chat."""
import contextlib
import hashlib
import json
from pathlib import Path
import random
import sqlite3
import subprocess
import tempfile
import time
import uuid

from task_effectiveness import rollout_metrics, runtime
from task_effectiveness_io import study_parser, wait_reply

ORIGINAL = '''import sys
import json


def records(text):
    lines = text.splitlines()
    if not lines:
        return []
    names = lines[0].split(",")
    return [dict(zip(names, row.split(","))) for row in lines[1:] if row]


if __name__ == "__main__":
    print(json.dumps(records(sys.stdin.read())))
'''
CONTRACT = ("The importer reads comma-separated UTF-8 text with a header and prints one JSON array. "
            "Keep all values as strings, including empty and padded fields. Ignore blank records. "
            "Use CSV double-quote escaping. Preserve embedded line breaks. "
            "An optional UTF-8 BOM before the first header is not part of the header. "
            "Empty input and header-only input produce an empty array. Runtime dependencies: Python standard library.\n")
HINT = "Sprawdź całą umowę wejścia w README, w tym przypadki spoza zgłoszonego przykładu."


SIZE_HINT = "Sprawdź przez publiczne polecenie również długi rekord, który przyjmowała poprzednia wersja. Zachowaj obsługiwany rozmiar pól."


def examples(seed, *, extended=False):
    value = str(random.Random(seed).randrange(1000000))
    cases = {
        "reported": ('id,note\n' + value + ',"red,blue"\n', [{"id": value, "note": "red,blue"}]),
        "escaped_quotes": ('id,note\n' + value + ',"a ""b"""\n', [{"id": value, "note": 'a "b"'}]),
        "multiline": ('id,note\n' + value + ',"x\n\ny"\n', [{"id": value, "note": "x\n\ny"}]),
        "bom": ('\ufeffid,note\r\n' + value + ',żółć\r\n', [{"id": value, "note": "żółć"}]),
        "spaces_and_empty": ('id,note\n\n' + value + ',  tekst  \n' + value + ',\n',
                             [{"id": value, "note": "  tekst  "}, {"id": value, "note": ""}]),
        "empty": ("", []), "header_only": ("id,note\n", []),
    }
    if extended:
        for name, ending in (("embedded_crlf", "\r\n"), ("embedded_cr", "\r")):
            cell = "jeden" + ending + "dwa"
            cases[name] = ('id,note\r\n' + value + ',"' + cell + '"\r\n', [{"id": value, "note": cell}])
        long_cell = "xy" * (70000 + seed % 5000) + ",koniec"
        cases["long_quoted"] = ('id,note\n' + value + ',"' + long_cell + '"\n', [{"id": value, "note": long_cell}])
    return cases


def grade(program, seed, *, extended=False):
    # Run the submitted entry point with no network and no access to the research host's home.
    command = ["bwrap", "--die-with-parent", "--unshare-all", "--ro-bind", "/usr", "/usr",
               "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
               "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
               "--ro-bind", str(program), "/importer.py", "/usr/bin/python3", "-I", "-B", "/importer.py"]
    checks = {}
    for name, (text, expected) in examples(seed, extended=extended).items():
        if program.is_symlink() or not program.is_file():
            checks[name] = False
            continue
        try:
            result = subprocess.run(command, env={"LANG": "C.UTF-8", "PATH": "/usr/bin"}, input=text.encode("utf-8"),
                                    capture_output=True, timeout=5)
            checks[name] = result.returncode == 0 and json.loads(result.stdout) == expected
        except (ValueError, subprocess.TimeoutExpired):
            checks[name] = False
    return checks


def trial(args, seed, guided):
    with tempfile.TemporaryDirectory(prefix="sw-csv-study-") as temp, contextlib.ExitStack() as stack:
        root = Path(temp)
        work = root / "agents" / str(uuid.uuid4())
        work.mkdir(parents=True)
        program, readme = work / "importer.py", work / "README.md"
        program.write_text(ORIGINAL)
        readme.write_text(CONTRACT)
        example, _ = examples(seed)["reported"]
        guidance = (SIZE_HINT if args.size_hint else HINT) if guided else None
        prompt = ("Napraw importer. W pliku CSV komórka zawierająca przecinek traci część tekstu. "
                  "Poniżej dane od użytkownika. Zachowaj obsługę dotychczasowych plików i interfejs "
                  "python3 importer.py. Zostaw naprawę w importer.py zgodnie z README.md i daj mi znać, czy działa.\n"
                  + example + ("\n" + guidance if guidance else ""))
        api = runtime(root, work, args, stack)
        start = time.monotonic()
        status, agent = api.call("/api/agents", dict(name="research", template="swarmhub-codex", workspace_id=work.name,
                                 model_id=args.model, task=prompt), timeout=90)
        if status != 201:
            raise RuntimeError(f"session launch returned {status}")
        key = agent["address"], agent["created_ms"]
        with contextlib.closing(sqlite3.connect(root / "db/workspace.sqlite3")) as db:
            _, reply = wait_reply(db, key, 0, args.timeout)
        elapsed = round(time.monotonic() - start, 1)
        api.call(f"/api/agents/{key[0]}/{key[1]}/end", {}, timeout=30)
        calls, models = rollout_metrics(root)
        checks = grade(program, seed, extended=args.extended)
        checks.update(model=models == [args.model], delivered=bool(reply),
                      contract_preserved=not readme.is_symlink() and readme.is_file() and readme.read_text() == CONTRACT)
        return dict(seed=seed, model=args.model, hint=guided, guidance=guidance, extended=args.extended, checks=checks, passed=all(checks.values()),
                    seconds=elapsed, calls=calls, reply=reply,
                    source_sha256=hashlib.sha256(program.read_bytes()).hexdigest() if program.is_file() and not program.is_symlink() else None)


if __name__ == "__main__":
    parser = study_parser(__doc__, timeout=180)
    parser.add_argument("--extended", action="store_true", help="Also check embedded CRLF, CR, and a large quoted field.")
    parser.add_argument("--size-hint", action="store_true", help="Compare the size compatibility reminder with the baseline.")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="sw-csv-calibration-") as temp:
        known = Path(temp) / "importer.py"
        known.write_text(ORIGINAL)
        baseline = grade(known, args.seeds[0])
        if {name for name, passed in baseline.items() if passed} != {"empty", "header_only", "spaces_and_empty"}:
            raise RuntimeError("Unexpected grading baseline. Check Python and bubblewrap before running sessions.")
    with args.output.open("x", buffering=1) as out:
        for seed in args.seeds:
            for guided in ([True, False] if seed % 2 else [False, True]):
                print(json.dumps(trial(args, seed, guided), ensure_ascii=False), file=out)
