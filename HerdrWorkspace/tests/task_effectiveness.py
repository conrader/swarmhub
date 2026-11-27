"""Paired real-model trials through an isolated SwarmHub bridge and Core."""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import secrets
import shlex
import sqlite3
import subprocess
import tempfile
import time
import uuid

from task_effectiveness_cases import CASES, GUIDANCE, setup, grade, check_proposal
from update_smoke import Server, free_port


def runtime(root, workspace, args, stack):
    home = root / "codex"
    for sub in ("codex", "run", "state", "config/herdr-core/templates", "db", "cache", "data"):
        (root / sub).mkdir(parents=True, exist_ok=True, mode=0o700)
    (home / "auth.json").symlink_to(args.auth)
    (home / "config.toml").write_text(
        f'model = {json.dumps(args.model)}\nmodel_reasoning_effort = "medium"\n'
        'approval_policy = "never"\nsandbox_mode = "workspace-write"\n'
        'check_for_update_on_startup = false\n'
        '[sandbox_workspace_write]\nnetwork_access = false\nexclude_slash_tmp = true\nexclude_tmpdir_env_var = true\n'
        f'[projects.{json.dumps(str(workspace))}]\ntrust_level = "trusted"\n')
    env = dict(HOME=str(root), CODEX_HOME=str(home), PATH="/usr/bin:/bin", LANG="C.UTF-8",
               HC_SOCKET=str(root / "hc.sock"), HC_SESSION="research", XDG_RUNTIME_DIR=str(root / "run"),
               XDG_STATE_HOME=str(root / "state"), XDG_CONFIG_HOME=str(root / "config"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"))
    (root / "db/first-time.json").write_text(json.dumps({"codex_hooks": True}))
    (root / "db/runtime-catalog.json").write_text(json.dumps(
        {"swarmhub-codex": {"harness": "Codex", "discover_models": True, "model_transport": "environment"}}))
    command = f"CODEX_HOME={shlex.quote(str(home))} SWARMHUB_CODEX_BIN={shlex.quote(str(args.codex))} {shlex.quote(str(args.bridge))} run-codex"
    (root / "config/herdr-core/templates/swarmhub-codex.md").write_text(
        f"---\ndescription: Task effectiveness research\ncommand: {command}\n---\n")

    def core(action):
        subprocess.run([args.core, "server", action], env=env, cwd=root, check=True,
                       capture_output=True, timeout=20)

    core("start")
    stack.callback(core, "stop")
    port, token = free_port(), secrets.token_hex(32)
    log = stack.enter_context((root / "bridge.log").open("w"))
    proc = subprocess.Popen([args.bridge], env=dict(env, SWARMHUB_DATA_DIR=str(root / "db"),
                            SWARMHUB_AGENT_CWD=str(root / "agents"), SWARMHUB_ACCESS_TOKEN=token,
                            SWARMHUB_PORT=str(port)), cwd=root, stdout=log, stderr=log)

    def shutdown():
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    stack.callback(shutdown)
    api = Server(port, token)
    api.becomes(args.bridge_version)
    return api


def rollout_metrics(root, *, parent_model_only=False):
    calls = 0
    models = set()
    for path in (root / "codex/sessions").rglob("rollout-*.jsonl"):
        child = False
        for line in path.read_text(errors="replace").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            payload = record.get("payload") or {}
            if record.get("type") == "session_meta":
                source = payload.get("source")
                child = isinstance(source, dict) and "subagent" in source
            if record.get("type") == "turn_context" and payload.get("model"):
                if not parent_model_only or not child:
                    models.add(payload["model"])
            if record.get("type") == "response_item" and payload.get("type") in ("function_call", "custom_tool_call"):
                calls += 1
    return calls, sorted(models)


def trial(args, case, seed, arm):
    with tempfile.TemporaryDirectory(prefix="sw-eval-") as temporary, contextlib.ExitStack() as stack:
        root = Path(temporary)
        workspace = root / "agents" / str(uuid.uuid4())
        workspace.mkdir(parents=True)
        prompt, truth = setup(workspace, case, seed)
        if arm == "guided":
            prompt += "\n" + args.guidance
        api = runtime(root, workspace, args, stack)
        start = time.monotonic()
        code, agent = api.call("/api/agents", {"name": "research", "template": "swarmhub-codex",
                               "workspace_id": workspace.name, "model_id": args.model, "task": prompt}, timeout=90)
        if code != 201:
            raise RuntimeError(f"agent launch failed ({code}): {str(agent)[:240]}")
        key = (agent["address"], agent["created_ms"])
        db = root / "db/workspace.sqlite3"

        def wait_for_reply(conn, after):
            while time.monotonic() - start < args.timeout:
                row = conn.execute("SELECT r.id FROM journal r JOIN journal t ON r.reply_for=t.launch_key "
                                   "WHERE r.kind='reply' AND t.address=? AND t.created_ms=? AND r.id>? "
                                   "ORDER BY r.id LIMIT 1", (*key, after)).fetchone()
                if row:
                    return row[0]
                time.sleep(1)
            return None

        stage_checks = {}
        with contextlib.closing(sqlite3.connect(db)) as conn:
            reply = wait_for_reply(conn, 0)
            turns = int(reply is not None)
            if case in ("resume", "partial_resume", "short_consent") and reply:
                stage_checks = check_proposal(workspace, truth, allow_paths_object=case == "partial_resume")
                if case == "short_consent":
                    text, = conn.execute("SELECT text FROM journal WHERE id=?", (reply,)).fetchone()
                    stage_checks["visible_plan"] = all(name in (text or "") for name in truth["eligible"])
                if all(stage_checks.values()):
                    route = f"/api/agents/{key[0]}/{key[1]}/messages"
                    consent = "Tak. Zatwierdzam usunięcie dokładnie tych plików: " + ", ".join(sorted(truth["eligible"]))
                    if case == "short_consent":
                        consent = "Tak"
                    if case == "partial_resume":
                        consent = (f"Z planu zatwierdzam tylko {truth['approved']}. Wykonaj zatwierdzoną część. "
                                   "Zachowaj pozostałe pliki. Jeśli wciąż brakuje miejsca, zapisz w request.json "
                                   "obiekt z polami missing (brakujące jednostki) i file (ścieżka do zatwierdzenia).")
                    code, _ = api.call(route, {"text": consent}, timeout=45)
                    if not 200 <= code < 300:
                        raise RuntimeError(f"follow-up delivery failed ({code})")
                    reply = wait_for_reply(conn, reply)
                    turns += int(reply is not None)
        elapsed = round(time.monotonic() - start, 1)
        api.call(f"/api/agents/{key[0]}/{key[1]}/end", {}, timeout=30)
        calls, models = rollout_metrics(root)
        checks = {**stage_checks, **grade(workspace, case, truth)}
        if case in ("resume", "partial_resume", "short_consent"):
            checks["two_replies"] = turns == 2
        return dict(case=case, seed=seed, arm=arm, model=args.model, observed_models=models,
                    guidance_sha256=hashlib.sha256(args.guidance.encode()).hexdigest() if arm == "guided" else None,
                    status="reply" if reply else "timeout", turns=turns, seconds=elapsed, tool_calls=calls,
                    checks=checks, passed=bool(reply) and models == [args.model] and all(checks.values()))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("bridge", "core", "codex", "auth"):
        p.add_argument("--" + name, type=Path, required=True)
    p.add_argument("--bridge-version", default="0.2.44")
    p.add_argument("--model", default="gpt-6.2-astra")
    p.add_argument("--seeds", type=int, nargs="+", default=[41, 73])
    p.add_argument("--cases", choices=CASES, nargs="+", default=CASES)
    p.add_argument("--reverse-order", action="store_true", help="Swap arm order when splitting seeds across jobs")
    p.add_argument("--timeout", type=int, default=180)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--guidance-file", type=Path, help="Replace the candidate guidance for this experiment")
    args = p.parse_args()
    args.guidance = args.guidance_file.read_text().strip() if args.guidance_file else GUIDANCE
    if not args.guidance or args.timeout < 1:
        p.error("guidance and a positive timeout are required")
    for name in ("bridge", "core", "codex", "auth"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    with args.output.open("x", buffering=1) as out:
        for index, seed in enumerate(args.seeds):
            for j, case in enumerate(args.cases):
                arms = ("baseline", "guided") if (index + j + args.reverse_order) % 2 == 0 else ("guided", "baseline")
                for arm in arms:
                    row = trial(args, case, seed, arm)
                    print(json.dumps(row, sort_keys=True), file=out)
                    print(case, seed, arm, row["status"], row["passed"], row["seconds"], flush=True)


if __name__ == "__main__":
    main()
