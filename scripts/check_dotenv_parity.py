#!/usr/bin/env python3
"""Compare the env reader with an external python-dotenv oracle, without installing it.

python3 -B scripts/check_dotenv_parity.py --dotenv-path /path/to/site-packages
Hermes 0.20.5 ships python-dotenv 1.2.2. Only this check imports the oracle.
Outputs counts and failing sample indexes, never environment values.
"""
import argparse
import importlib.util
import io
import itertools
import json
from pathlib import Path
import sys
from unittest.mock import patch


def samples():
    # The original 21 named values plus 3,108 short quoted strings (3,129 total).
    named = ['plain', 'plain # note', '"double quoted"', "'single quoted'", '"a # b"', '""', "''", '',
             r'"say \"hi\" \\ done"', r'"tab\there"', r'"new\nline"', r'"it\'s"', r'"caf\u00e9\/x"', r'"C:\data\x41"',
             r"'it\'s'", r"'back\\slash'", r"'keep\nliteral'", r"'a\\\'b'", '"café"', r'"\\\\"', r"'\\\\'"]
    brute = [quote + "".join(content) + quote for size in range(1, 5)
             for content in itertools.product(['a', '\\', "'", '"', 'n', 'u'], repeat=size) for quote in ('"', "'")]
    original = ["KEY=" + value + "\n" for value in named + brute]
    extended = ["export KEY=" + quote + content + quote + suffix + newline + "NEXT=after" + newline
                for quote in ("'", '"') for content in ("", "a # b", "first\nsecond", "a\n\n# b\nNEXT=inside",
                                                        "a\\\nb", "a\u2028b", "café\n雪")
                for suffix in ("", " # note", "# note with ' and \"", "\t# note") for newline in ("\n", "\r\n", "\r")]
    extended += ["KEY=\"x\" # EOF", "KEY='first\nsecond'", "KEY=\"first\nsecond", "KEY='first\nsecond' trailing",
                 "KEY=valid\nBROKEN=\"unterminated", "KEY='a'b'", "KEY=\"a\"b\"", "KEY=\"a\" 'b'", "KEY=\"a\"\\\n",
                 "# comment\nBARE_KEY\nKEY=last", "'quoted key'=value", "export\tKEY = value # comment", "1KEY=value",
                 "KEY= # comment", "KEY=\nNEXT=last", "KEY=first\nKEY=second", "KEY=first\nKEY", "KEY=first\nKEY=",
                 "not an assignment", "=missing-key", "''=empty-key", "export ", "KEY=\v'quoted'\f# comment"]
    return {"original": original, "extended": extended}


class MemoryFile:
    def __init__(self, text):
        self.text = text

    def is_file(self):
        return True

    def read_text(self):
        return self.text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotenv-path", required=True, type=Path)
    parser.add_argument("--reader-path", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Resources/Skills/swarmhub-manager/scripts/connectors_files.py")
    args = parser.parse_args()
    sys.path.insert(0, str(args.dotenv_path))
    from dotenv.parser import parse_stream
    from dotenv.version import __version__
    sys.path.pop(0)
    spec = importlib.util.spec_from_file_location("parity_reader", args.reader_path)
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    report = {"oracle_version": __version__}
    for name, inputs in samples().items():
        counts = {"samples": len(inputs), "accepted": 0, "rejected": 0, "differences": 0, "failing_indexes": []}
        for index, text in enumerate(inputs):
            bindings = list(parse_stream(io.StringIO(text)))
            malformed = any(binding.error for binding in bindings)
            expected = {b.key: b.value for b in bindings if b.key is not None and b.value is not None}
            with patch.dict(reader.os.environ, {}, clear=True):
                try:
                    actual = reader.environment_values([MemoryFile(text)])
                    differs = malformed or actual != expected
                except ValueError:
                    differs = not malformed
            counts["rejected" if malformed else "accepted"] += 1
            if differs:
                counts["differences"] += 1
                counts["failing_indexes"].append(index)
        report[name] = counts
    print(json.dumps(report, indent=2))
    return int(any(report[name]["differences"] for name in samples()))


if __name__ == "__main__":
    sys.exit(main())
