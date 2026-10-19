#!/usr/bin/env python3
"""Pass 9: shipped managed entrypoints, real QA Hermes, no server installation.

The loopback bridge namespaces five QA roles and explicitly invokes the shipped
pre/post hook functions in isolated child processes. It is not plugin activation.
No fake CLI, curl, model answer, report artifact or successful job is supplied.
When an authenticated Codex CLI is available, P01/P04 use model-selected bounded
local actions and real jobs in an environment-addressed throwaway git repository.
Missing authentication marks those chains failed/untested, never successful.
"""
from contextlib import ExitStack
import argparse
import http.client
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from live_behavior import BehaviorSuite, answer, successful
from live_cli import RULES, cli_env, coding_cli, pid_alive, qa_repo, qa_git_env, writable_cli_state, source_auth_snapshot  # noqa: F401
from test_peer_runtime import children_by_home
from live_chains import ChainMixin

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Resources/Skills/swarmhub-messages/scripts"
JOB = ROOT / "Resources/Skills/swarmhub-coding/scripts/code-job"
ROLES = {"QA-Jarvis", "QA-Swarmhub", "QA-Ermes", "QA-Infra", "QA-Konrad"}
APP_CONTRACT = "Only the configured role is accepted" + (SCRIPTS.parent / "SKILL.md").read_text().split(
    "Only the configured role is accepted", 1)[1]


def hook_main():
    import runpy
    sys.path.insert(0, str(SCRIPTS))
    peer = runpy.run_path(str(SCRIPTS / "peer-runtime.py"))
    op, args = json.load(sys.stdin)
    print(json.dumps(peer[op](*args)))


class ManagedSuite(ChainMixin, BehaviorSuite):
    def __init__(self, output):
        super().__init__(output)
        self.run = "QA-LIVE9-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
        self.commands, self.hooks = [], []
        self.sequence = 0
        self._resources = ExitStack()
        self.temp = Path(self._resources.enter_context(tempfile.TemporaryDirectory(prefix="QA-LIVE9-")))
        try:
            self.initialize_local()
        except BaseException:
            self._resources.close()
            raise

    def initialize_local(self):
        self.private_values = []
        self.home = self.temp / "QA-home"
        self.state = self.home / ".hermes/swarmhub"
        self.server = None
        self.base_env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.temp),
                         "PYTHONDONTWRITEBYTECODE": "1"}
        self.cli = writable_cli_state(coding_cli(), self.temp / "QA-codex-state")
        self.source_auth_before = source_auth_snapshot(self.cli) if self.cli else None
        self.child_env = cli_env(self.base_env, self.cli)
        self.model = os.environ.get("QA_CODING_MODEL", "gpt-6-astra")
        self.repo = qa_repo(self.temp / "QA-repo", writable_git=True) if self.cli else None
        if self.repo:
            self.child_env = qa_git_env(self.repo, self.child_env)
            self.init_chain_verifier()
        for role in ROLES:
            folder = self.home / ".hermes/profiles" / role
            folder.mkdir(parents=True, mode=0o700)
            env = folder / ".env"
            env.write_text("API_SERVER_KEY=" + self.key + "\n")
            env.chmod(0o600)

    def save(self):
        super().save()
        path = self.output / "results.json"
        data = json.loads(path.read_text())
        data.update(commands=self.commands, hooks=self.hooks, baseline="grokbot-observed.md P01-P10",
                    scope="real Hermes + unmodified managed scripts; external hook and bounded reply-action bridges; no installed plugin; coding CLI: "
                          + (self.cli["path"] + " (authenticated, real jobs in a throwaway repo)" if self.cli else "none (jobs fail 69)"),
                    coding_cli=self.cli, cli_execution_path=os.environ.get("QA_CLI_EXECUTION_PATH", "unspecified caller; unchanged code-job workspace-write"),
                    qa_git_layout={"work_tree": str(self.repo), "git_dir": str(self.repo / "QA-git-store"),
                                   "dot_git_entry": False} if self.repo else None,
                    app_contract_source="Resources/Skills/swarmhub-messages/SKILL.md 1.3.5")
        path.write_text(self.clean(json.dumps(data, indent=2)) + "\n")

    def request(self, label, path, method="GET", body=None, **kwargs):
        if method == "POST" and path.endswith("/chat/stream"):
            with self.usage_lock:
                self.capture_usage()
                if self.turns >= 24 or self.observed_calls >= 24:
                    raise RuntimeError("Pass 9 Hermes call reserve reached")
        return super().request(label, path, method, body, **kwargs)

    def clean(self, value):
        value = super().clean(value)
        for secret in getattr(self, "private_values", []):
            value = value.replace(secret, "[REDACTED]")
        return value

    def command(self, label, argv, payload=None, actor=None, expected=0, env=None, private_input=None):
        env = dict(self.child_env if env is None else env)
        if actor:
            env["HERMES_HOME"] = str(self.home / ".hermes/profiles" / actor)
        start = time.monotonic()
        proc = subprocess.run(argv, input=private_input if private_input is not None else json.dumps(payload) if payload is not None else None,
                              env=env, text=True, capture_output=True, timeout=25 if self.cli is None else 900)
        rec = {"label": label, "argv": argv, "payload": json.loads(self.clean(json.dumps(payload))), "administrative_fixture_actor": actor,
               "returncode": proc.returncode, "stdout": self.clean(proc.stdout),
               "stderr": self.clean(proc.stderr), "seconds": round(time.monotonic()-start, 3)}
        self.commands.append(rec)
        self.save()
        self.result(label, proc.returncode == expected, "entrypoint exit=" + str(proc.returncode), label)
        if proc.returncode != expected:
            raise RuntimeError(label + " unexpected exit")
        return proc.stdout.strip()

    def ctl(self, label, *args, payload=None, actor=None, expected=0):
        return self.command(label, ["/usr/bin/python3", str(SCRIPTS / "swarmctl"), *args], payload, actor, expected)

    def decoded_ctl(self, label, *args, **kwargs):
        value = self.ctl(label, *args, **kwargs)
        return value if value.startswith("task.") else json.loads(value)

    def msg(self, label, source, target, text, *flags):
        return self.command(label, ["/bin/sh", str(SCRIPTS / "bot-msg"), "--from", source, "--to", target,
                                   *flags, "--", "[QA-TEST] " + text])

    def hook(self, op, *args):
        proc = subprocess.run(["/usr/bin/python3", str(Path(__file__).resolve()), "--hook"],
                              input=json.dumps([op, args]), capture_output=True, text=True,
                              env=self.child_env, timeout=10)
        if proc.returncode:
            raise RuntimeError("Local hook failed: " + proc.stderr)
        value = json.loads(proc.stdout)
        with self.lock:
            self.hooks.append({"op": op, "args": args, "result": value})
        return value

    def bridge(self, port=0):
        suite = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                sent = False
                try:
                    if self.headers.get("Authorization") != "Bearer " + suite.key:
                        raise ValueError("Invalid bridge authorization")
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 40000:
                        raise ValueError("Invalid request length")
                    raw = json.loads(self.rfile.read(size))
                    match = re.fullmatch(r"/p/(QA-[A-Za-z]+)/api/sessions(?:/swarmhub-from-(QA-[A-Za-z]+)/chat/stream)?", self.path)
                    if not match or match[1] not in ROLES:
                        raise ValueError("Unowned route")
                    target, sender = match.groups()
                    sender = sender or raw["id"].removeprefix("swarmhub-from-")
                    if sender not in ROLES:
                        raise ValueError("Unowned sender")
                    session = "swarmhub-from-" + sender
                    sid = f"{suite.run}-{target}-from-{sender}"
                    create = self.path.endswith("/api/sessions")
                    with suite.lock:
                        suite.sequence += 1
                        label = f"QA-bridge-{suite.sequence:03d}"
                        if create:
                            suite.owned.add(sid)
                        elif sid not in suite.owned:
                            raise ValueError("Unregistered session")
                    path = "/api/sessions" if create else f"/api/sessions/{sid}/chat/stream"
                    context = None if create else suite.hook("before_turn", target, session, label, raw["input"])
                    body = {"id": sid, "title": sid, "source": "api_server"} if create else {
                        "input": raw["input"], "instructions": (suite.chain_rules(target, raw["input"]) or RULES) +
                        " Your role is " + target + ".\n" + APP_CONTRACT + "\n" +
                        ((context or {}).get("context", ""))}
                    def relay(event, obj, trace):
                        nonlocal sent
                        if not sent:
                            self.send_response(trace["status"])
                            self.send_header("Content-Type", "text/event-stream")
                            self.end_headers()
                            sent = True
                        self.wfile.write(("event: " + event + "\ndata: " + json.dumps(obj) + "\n\n").encode())
                        self.wfile.flush()
                        return False
                    trace = suite.request(label, path, "POST", body, timeout=45, on_frame=None if create else relay)
                    if not create and successful(trace):
                        suite.hook("after_turn", target, session, label, answer(trace))
                    if not sent:
                        self.send_response(trace.get("status", 502))
                        self.end_headers()
                        self.wfile.write(trace.get("body", "").encode())
                except Exception as exc:
                    if not sent:
                        self.send_response(403)
                        self.end_headers()
                        self.wfile.write(type(exc).__name__.encode())
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.server = server
        self.child_env["SWARMHUB_GATEWAY"] = f"http://127.0.0.1:{server.server_port}"
        self.base_env["SWARMHUB_GATEWAY"] = self.child_env["SWARMHUB_GATEWAY"]
        return server.server_port

    def snapshot(self, label):
        data = self.decoded_ctl(label, "status")
        self.export_local(label)
        return data

    def export_local(self, label):
        import sqlite3
        data = {"time": datetime.now(timezone.utc).isoformat(), "files": {}}
        for path in sorted(self.state.glob("job-completions/job.*/*")):
            if path.is_file():
                data["files"][str(path.relative_to(self.state))] = path.read_text(errors="replace")
        if self.repo:
            data["coding_artifacts"] = {p.name: p.read_text(errors="replace") for p in self.repo.iterdir() if p.is_file()}
        if self.cli:
            sessions = Path(self.cli["codex_home"]) / "sessions"
            for path in sessions.rglob("*.jsonl"):
                audit = []
                for line in path.read_text().splitlines():
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        # A process killed during a JSONL append can leave a partial last record.
                        audit.append({"type": "incomplete-record", "payload": {}})
                        continue
                    value = record.get("payload", {})
                    kind = record.get("type")
                    if kind == "session_meta":
                        value = {k: value.get(k) for k in ("id", "timestamp", "cwd", "cli_version", "model_provider")}
                    elif kind == "turn_context":
                        value = {k: value.get(k) for k in ("turn_id", "cwd", "model", "effort", "approval_policy", "sandbox_policy")}
                    elif kind == "token_usage_record":
                        value = {k: value.get(k) for k in ("response_id", "usage", "turn_token_usage", "thread_token_usage")}
                    elif kind == "event_msg" and value.get("type") in ("task_started", "task_complete", "error"):
                        pass
                    elif kind == "response_item" and value.get("type") in ("custom_tool_call", "function_call"):
                        value = {k: value.get(k) for k in ("type", "call_id", "name", "input", "arguments")}
                    elif kind == "response_item" and value.get("type") == "message" and value.get("role") == "assistant":
                        value = {k: value.get(k) for k in ("type", "role", "content", "phase")}
                    else:
                        continue
                    audit.append({"time": record.get("timestamp"), "type": kind, "payload": value})
                target = self.output / ("QA-cli-audit-" + path.stem + ".json")
                target.write_text(self.clean(json.dumps(audit, indent=2)) + "\n")
        for name in ("control.sqlite", "peer-inbox.sqlite"):
            path = self.state / name
            if path.exists():
                with sqlite3.connect("file:" + str(path) + "?mode=ro", uri=True) as db:
                    db.row_factory = sqlite3.Row
                    tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
                    data[name] = {table: [dict(r) for r in db.execute('SELECT * FROM "' + table + '"')] for table in tables}
        (self.output / (label + ".json")).write_text(self.clean(json.dumps(data, indent=2)) + "\n")

    def until(self, predicate, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                self.capture_usage()
                return
            time.sleep(.2)
        raise RuntimeError("Timed out waiting for runtime state")

    def idle(self):
        def settled():
            import sqlite3
            if list(self.temp.glob("bot-msg-late.*")):
                return False
            if (self.state / "control.sqlite").exists():
                with sqlite3.connect(self.state / "control.sqlite") as db:
                    if db.execute("SELECT count(*) FROM deliveries WHERE status='pending'").fetchone()[0]:
                        return False
            jobs = list(self.state.glob("job-completions/job.*/ready"))
            return all((p.parent / "delivered").exists() for p in jobs)
        self.until(settled)

    def coding(self, intent, origin="QA-Jarvis", mode="add", commit=True):
        if self.cli:
            work = ("Fix qa_work.add(a,b) to return a+b, preserving any existing correct functions."
                    if mode == "add" else
                    f"Add qa_work.{mode}(a,b) returning " + ("a*b." if mode == "multiply" else "a-b.") +
                    " Preserve all existing functions.")
            return {"bot": "QA-Swarmhub", "origin": origin, "kind": "coding", "intent": intent,
                    "task": f"QA replay {intent}: {work} Append the line '{intent} done' to NOTES.md. "
                            "This is an authorized throwaway repository with writable git metadata in QA-git-store "
                            "(GIT_DIR/GIT_WORK_TREE are set). For tool shells, use explicit "
                            f"git --git-dir={self.repo}/QA-git-store --work-tree={self.repo} commands if needed. "
                            + (f"Commit qa_work.py and NOTES.md with message 'QA: {intent}'. A new commit is required. "
                               if commit else "Do not commit: the ordering bot must review and commit these actual changes after completion. ") +
                            "Do not change QA-git-store directly, .gitignore, the verifier, or QA-REVIEW.md. "
                            "Use no network, send nothing anywhere. Run the configured verification: " + self.verify_command(intent, mode),
                    "directory": str(self.repo), "order": "codex", "model": self.model, "effort": "high",
                    "report": str(self.repo / (intent + ".txt")), "verify": self.verify_command(intent, mode)}
        return {"bot": "QA-Swarmhub", "origin": origin, "kind": "coding", "intent": intent,
                "task": "QA replay: review result, verify report, rebuild and take the next authorized step. No outbound.",
                "directory": str(self.home), "order": "codex", "model": self.model, "effort": "high",
                "report": str(self.home / (intent + ".txt"))}

    def job_field(self, ident, name):
        path = self.state / "job-completions" / ident.replace("task.", "job.") / name
        return path.read_text().strip() if path.exists() else None

    def webhook_replay(self):
        record = self.decoded_ctl("P02-webhook-register", "webhook", "register", "QA-Infra", "QA-wake")
        key_file = Path(record["key_file"])
        old_key = key_file.read_text().strip()
        self.private_values.append(old_key)
        self.result("P02-webhook-private-key", key_file.stat().st_mode & 0o777 == 0o600 and
                    key_file.parent.stat().st_mode & 0o777 == 0o700, "Key 0600, directory 0700; only path exported")
        same = self.decoded_ctl("P02-webhook-idempotent", "webhook", "register", "QA-Infra", "QA-wake")
        self.result("P02-webhook-stable-registration", same == record, "Registration is idempotent")
        slug = record["url"].rsplit("/", 1)[1]
        self.ctl("P02-webhook-fire", "webhook", "fire", "QA-Infra", "QA-wake", slug,
                 payload={"key": old_key, "text": "[QA-TEST] FYI QA registered webhook fired. NO_REPLY."})
        self.idle()
        self.ctl("P02-webhook-rotate", "webhook", "rotate", "QA-Infra", "QA-wake")
        new_key = key_file.read_text().strip()
        self.private_values.append(new_key)
        self.ctl("P02-webhook-reject-old-key", "webhook", "fire", "QA-Infra", "QA-wake", slug,
                 payload={"key": old_key, "text": "[QA-TEST] Must never deliver"}, expected=77)
        ready = self.temp / "QA-webhook-port"
        code = ("import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); import swarm_webhook; "
                "swarm_webhook.serve(0, ready=lambda port: Path(sys.argv[2]).write_text(str(port)))")
        receiver = subprocess.Popen(["/usr/bin/python3", "-B", "-c", code, str(SCRIPTS), str(ready)],
                                    env=self.child_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.until(ready.exists, 10)
            port = int(ready.read_text())
            for label, key, expected in (("stale", old_key, 403), ("rotated", new_key, 202)):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                try:
                    conn.request("POST", record["url"].split(":8745", 1)[1],
                                 json.dumps({"text": "[QA-TEST] FYI QA rotated webhook HTTP wake. NO_REPLY."}),
                                 {"X-SwarmHub-Key": key, "Content-Type": "application/json"})
                    response = conn.getresponse()
                    body = response.read().decode()
                    self.result("P02-webhook-http-" + label, response.status == expected,
                                f"HTTP {response.status}; {body}")
                finally:
                    conn.close()
            self.idle()
        finally:
            receiver.terminate()
            receiver.wait(timeout=10)
        self.snapshot("QA-P02-webhook")

    def provision_replay(self):
        # This hook only writes a local QA receipt; it provisions no host and sends nothing.
        synthetic = "QA-synthetic-" + secrets.token_urlsafe(24)
        self.private_values.append(synthetic)
        intake = json.loads(self.command("P06-secure-intake", ["/usr/bin/python3", str(SCRIPTS / "swarmctl"),
                                  "secret", "intake", "QA-model-key"], private_input=synthetic + "\n"))
        path = Path(intake["path"])
        hook = self.home / "QA-synthetic-provisioner.py"
        receipt = self.home / "QA-synthetic-provision-receipt.json"
        hook.write_text("import json,sys\nfrom pathlib import Path\n"
                        "request=json.loads(sys.argv[sys.argv.index('--request')+1])\n"
                        "p=Path(request['model_key'])\n"
                        "assert p.is_file() and p.stat().st_mode & 0o777 == 0o600\n"
                        f"Path({str(receipt)!r}).write_text(json.dumps({{'FAKE':True,'request':request,'mode':'0600'}}))\n")
        self.ctl("P06-configure-synthetic-provisioner", "policy", "set",
                 payload={"provisioner": ["/usr/bin/python3", str(hook)]})
        ident = self.decoded_ctl("P06-synthetic-provision-gate", "submit", payload={
            "bot": "QA-Ermes", "kind": "provision", "intent": "QA-P06-synthetic-provision",
            "request": {"name": "QA-Hermes", "model_key": str(path)}})
        self.result("P06-owner-gate-before-hook", self.action_status(ident) == "awaiting-owner" and not receipt.exists(),
                    "Synthetic hook cannot execute before owner decision")
        self.ctl("P06-wrong-actor-rejected", "decide", ident, "QA-Jarvis", "approve", actor="QA-Jarvis", expected=64)
        self.ctl("P06-admin-fixture-approve", "decide", ident, "QA-Konrad", "approve", actor="QA-Konrad")
        self.until(lambda: self.action_status(ident) == "done")
        self.result("P06-synthetic-hook-completed", receipt.exists() and path.stat().st_mode & 0o777 == 0o600 and
                    path.read_text() == synthetic, "Synthetic provisioner consumed path; no real host or model key")
        self.snapshot("QA-P06-synthetic-provision")
        return path

    def execute(self):
        health = json.loads(self.request("QA-initial-health", "/health/detailed")["body"])
        if health.get("active_agents") or health.get("api_server", {}).get("active_runs"):
            raise RuntimeError("QA target must start idle")
        tools = json.loads(self.request("QA-toolsets", "/v1/toolsets")["body"])
        if {x["name"] for x in tools["data"] if x["enabled"]} != {"todo", "clarify"}:
            raise RuntimeError("Unexpected enabled tools")
        self.request("QA-capabilities", "/v1/capabilities")
        for role in sorted(ROLES):
            self.ctl("P02-register-" + role, "register", role, *( ["--coordinator"] if role == "QA-Jarvis" else []))
        self.ctl("P07-P08-policy", "policy", "set", payload={"coordinator": "QA-Jarvis", "owner": "QA-Konrad",
                 "timezone": "Europe/Warsaw", "start": 480, "end": 1380})

        if self.cli:
            self.run_chain("P01-full-chain", self.p01_chain)
            self.run_chain("P04-full-chain", self.p04_chain)
        else:
            self.result("P01-real-chain", False, "No authenticated coding CLI; commit/rebuild chain untested")
            self.result("P04-real-correction-chain", False, "No authenticated coding CLI; real empty-job correction untested")

        self.msg("P02-Infra-register-request", "QA-Infra", "QA-Swarmhub",
                 'Unknown launching agent must fall back to Jarvis. Register the wake subscription; secret key visible only to user, never in chat. '
                 'Runner will exercise managed webhook register/fire/rotate with a 0600 key file. No Hermes routine is installed. State the boundary.', "--durable")
        self.idle()
        # Fallback routing is about the failed job's wake, not the CLI: this direct job runs without the CLI on PATH.
        self.command("P02-unknown-origin-code-job", ["/bin/sh", str(JOB), "--bot", "QA-Swarmhub", "--origin", "QA-Unknown",
                     "--order", "codex", "--dir", str(self.home), "--model", self.model, "--effort", "high",
                     "--report", str(self.home / "QA-P02-report.txt"), "--verify", "test -s QA-P02-report.txt",
                     "--", "QA observed unknown-origin wake fallback"],
                     expected=69, env=self.base_env)
        self.idle()
        self.snapshot("QA-P02-fallback")
        self.webhook_replay()

        secret_path = self.provision_replay()
        before = self.turns
        self.msg("P03-held-FYI", "QA-Swarmhub", "QA-Ermes", "FYI held until your next turn: QA Hermes is for this team QA pass. No action requested.", "--held")
        self.result("P03-no-held-wake", self.turns == before, "Held admission caused zero HTTP/model requests")
        self.msg("P06-priority-late-provision", "QA-Swarmhub", "QA-Ermes",
                 'Priority: provision a QA Hermes; reply with chmod-600 secret-file path, never key contents. '
                 'Runner receipt: owner-approved SYNTHETIC provisioner completed for QA-Hermes, using synthetic intake at '
                 + str(secret_path) + ' (0600). No real host or model key. Report this path and ask for any real model key via '
                 'a swarmhub fence with op secret_request, name QA-model-key. All provisioning/outbound FAKE.',
                 "--priority", "--no-wait")
        self.until(lambda: not list(self.temp.glob("bot-msg-late.*")))
        self.snapshot("QA-P03-P06-held-and-late")
        provision = {"bot": "QA-Ermes", "kind": "provision", "intent": "QA-P06-provision", "risks": ["secrets"],
                     "fake": True, "argv": ["/usr/bin/touch", str(self.home / "QA-must-not-provision")]}
        ident = self.decoded_ctl("P06-provision-gate", "submit", payload=provision)
        self.ctl("P06-admin-fixture-deny", "decide", ident, "QA-Konrad", "deny", actor="QA-Konrad")

        self.ctl("P05-global-quota-policy", "policy", "set", payload={"route": "codex", "codex_model": "gpt-6-astra", "allow_speculative": False})
        for role in ("QA-Swarmhub", "QA-Infra", "QA-Ermes"):
            self.msg("P05-broadcast-" + role, "QA-Jarvis", role,
                     'Claude limit 95%: route to Codex, no speculative jobs. FYI; NO_REPLY.', "--durable")
        self.idle()
        self.ctl("P05-route-enforced", "plan", "claude", "0")
        self.ctl("P05-no-speculation", "submit", payload=dict(self.coding("QA-P05-speculative"), speculative=True), expected=64)
        self.snapshot("QA-P05-policy-acks")

        for risk in ("money", "prod", "secrets"):
            spec = {"bot": "QA-Swarmhub", "kind": risk, "intent": "QA-P07-"+risk, "fake": True, "argv": ["/bin/true"]}
            ident = self.decoded_ctl("P07-gate-"+risk, "submit", payload=spec)
            if risk == "money":
                card = {"op": "approval", "task": ident, "kind": risk, "gate": "owner", "decider": "QA-Konrad",
                        "bot": "QA-Swarmhub", "intent": spec["intent"], "summary": "QA FAKE money action", "risks": [risk]}
                self.msg("P07-present-approval-fence", "QA-Jarvis", "QA-Swarmhub",
                         "Runtime receipt: task awaits owner. Present exactly this JSON in a swarmhub fence, with no execution claim: "
                         + json.dumps(card, separators=(",", ":")), "--durable")
                self.idle()
            self.ctl("P07-deny-"+risk, "decide", ident, "QA-Konrad", "deny", actor="QA-Konrad")
            self.ctl("P07-denial-final-"+risk, "submit", payload=spec, expected=64)
        # Scope change propagates through a real held peer task tree; no fake CLI.
        parent_spec = dict(self.coding("QA-P07-old-scope"), risks=["prod"])
        parent = self.decoded_ctl("P07-old-scope", "submit", payload=parent_spec)
        child = self.decoded_ctl("P07-peer-child", "submit", payload={"bot": "QA-Ermes", "kind": "peer",
                           "parent": parent, "intent": "QA-P07-peer-child", "to": "QA-Infra", "text": "QA obsolete scope"})
        self.msg("P07-associated-held", "QA-Ermes", "QA-Infra", "QA obsolete scope", "--held", "--task-id", child)
        replacement = self.decoded_ctl("P07-replace-scope", "replace", parent, payload=dict(parent_spec, intent="QA-P07-corrected-scope"))
        self.snapshot("QA-P07-scope-cancel")
        if self.cli:
            # The earlier owner-gated replacement must not hold this bot's queue during the CLI cancellation probe.
            self.ctl("P07-stop-gated-fixture", "stop", replacement)
            # A running real coding process is killed by a scope change; the corrected job must then really launch.
            running = self.decoded_ctl("P07-running-scope", "submit", payload=dict(
                self.coding("QA-P07-running-scope"), task="QA replay: run the shell command `sleep 300` first, then append "
                "'slow' to NOTES.md and commit it. No network, send nothing."))
            job = self.state / "job-completions" / running.replace("task.", "job.")
            self.until(lambda: self.action_status(running) == "running" and (job / "cli-pid").exists(), 120)
            cli_pid = int((job / "cli-pid").read_text())
            alive = pid_alive(cli_pid) and not (job / "cli-exit").exists()
            self.result("P07-real-job-running", alive, "code-job and its CLI tree alive before the scope change")
            corrected = self.decoded_ctl("P07-kill-running-scope", "replace", running, payload=self.coding("QA-P07-running-scope-corrected"))
            self.until(lambda: (job / "ready").exists() and self.action_status(running) == "cancelled" and
                       not pid_alive(int((job / "pid").read_text())), 120)
            self.result("P07-running-process-killed", self.job_field(running, "status") == "cancelled" and
                        self.job_field(running, "cli-exit") == "125" and not pid_alive(cli_pid),
                        f"status {self.job_field(running, 'status')}; cli-exit {self.job_field(running, 'cli-exit')}")
            self.snapshot("QA-P07-running-scope-killed")
            self.until(lambda: self.action_status(corrected) in ("done", "failed"), 900)
            self.result("P07-corrected-scope-verified", self.action_status(corrected) == "done" and
                        self.job_field(corrected, "evidence") in ("commit", "tests", "commit+tests"),
                        "Replacement ran the real CLI; evidence=" + str(self.job_field(corrected, "evidence")))
        read = self.decoded_ctl("P09-autonomous-read", "submit", payload={"bot": "QA-Ermes", "kind": "read",
                          "intent": "QA-P09-pwd", "argv": ["/bin/pwd"]})
        marker = self.home / "QA-must-not-send"
        fake = self.decoded_ctl("P09-outbound-FAKE", "submit", payload={"bot": "QA-Infra", "kind": "outbound",
                          "intent": "QA-P09-draft", "fake": True, "argv": ["/usr/bin/touch", str(marker)],
                          "to": "QA-FAKE-recipient", "text": "FAKE draft only"})
        self.until(lambda: self.action_status(read) == "done" and self.action_status(fake) == "done")
        self.result("P09-no-send", not marker.exists(), "FAKE argv never executed; allowlisted read completed without approval")
        draft = {"bot": "QA-Infra", "kind": "outbound", "intent": "draft-00000000-0000-0000-0000-000000000005-0",
                 "to": "QA-FAKE-recipient", "text": "Subject: QA pass 5\n\nExact QA draft body.\nZażółć 🧪", "fake": True}
        draft_id = self.decoded_ctl("P07-exact-draft-FAKE-submit", "submit", payload=draft)
        repeated = self.decoded_ctl("P07-exact-draft-repeat", "submit", payload=draft)
        self.until(lambda: self.action_status(draft_id) == "done")
        self.result("P07-draft-idempotent", repeated == draft_id, "Exact app-shaped draft spec admitted once; no native UI click")
        self.msg("P07-P09-policy-result", "QA-Jarvis", "QA-Swarmhub",
                 'Konrad gates money/prod/secrets; Jarvis gates real outbound. User changed scope: local runtime cancelled old parent and peer child; ' +
                 ('a running CLI was cancelled and replacement verification was checked. ' if self.cli else
                  'replacement still awaits owner; no running CLI was killed or relaunched. ') + 'Each action should be autonomous: '
                 'allowlisted pwd completed and outbound recorded FAKE without execution. Do not ask for approval or claim a real send.', "--durable")
        self.idle()
        self.snapshot("QA-P09-autonomy")

        self.ctl("P08-report-real-current-time", "report", "QA-Swarmhub", "[QA-TEST] QA runtime replay result; no action remains. Reporting window: Konrad+Jarvis 08-23 Warsaw, Jarvis only otherwise. NO_REPLY.")
        self.idle()
        self.snapshot("QA-P08-report-delivery")

        # Actually close our loopback listener; Hermes itself remains unchanged.
        port = self.server.server_port
        self.server.shutdown()
        self.server.server_close()
        self.server = None
        self.msg("P10-offline-durable", "QA-Infra", "QA-Ermes",
                 'Target was offline; retry later, never claim success before delivery. Restored peer now receives this once; no action remains. NO_REPLY.', "--durable")
        self.until(lambda: self.delivery_attempts() > 0)
        self.snapshot("QA-P10-unreachable-pending")
        self.bridge(port)
        self.idle()  # No caller resend/tick or due-time edits: persistent worker retries.
        self.snapshot("QA-P10-automatic-retry")
        for sid in sorted(self.owned):
            self.history("final-" + sid, sid)

    def action_status(self, ident):
        import sqlite3
        with sqlite3.connect(self.state / "control.sqlite") as db:
            return db.execute("SELECT status FROM actions WHERE id=?", (ident,)).fetchone()[0]

    def delivery_attempts(self):
        import sqlite3
        with sqlite3.connect(self.state / "control.sqlite") as db:
            return db.execute("SELECT COALESCE(max(attempts),0) FROM deliveries WHERE status='pending'").fetchone()[0]

    def stop_local_processes(self):
        children = set(children_by_home(str(self.home)))
        # Include descendants whose sandbox correctly replaced HOME. Retain this
        # snapshot so an orphan cannot escape the final kill by being reparented.
        pairs = subprocess.check_output(["ps", "-A", "-o", "pid=", "-o", "ppid="], text=True)
        rows = [tuple(map(int, line.split())) for line in pairs.splitlines()]
        while True:
            expanded = children | {child for child, parent in rows if parent in children}
            if expanded == children:
                break
            children = expanded
        for pid in children:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        time.sleep(.5)
        for pid in children | set(children_by_home(str(self.home))):
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass

    def close_server(self):
        if self.server:
            try:
                self.server.shutdown()
            finally:
                self.server.server_close()
                self.server = None

    def export_final(self):
        self.export_local("QA-final-local-state")
        log = self.state / "bot-messages.log"
        if log.exists():
            (self.output / "QA-bot-messages.tsv").write_text(self.clean(log.read_text()))
        unchanged = self.cli is None or self.source_auth_before == source_auth_snapshot(self.cli)
        isolation = {"source_auth_config_unchanged": unchanged, "files": ["auth.json", "config.toml"],
                     "comparison": "contents, mode, inode, mtime; no source values exported"}
        (self.output / "QA-cli-isolation.json").write_text(json.dumps(isolation, indent=2) + "\n")
        self.result("source-auth-config-unchanged", unchanged, "Source auth/config contents and metadata unchanged")
        assert unchanged, "Source CLI auth/config changed; isolation evidence retained"

    def finish(self):
        errors = []
        # Quiesce writers first; every stage runs even if any other stage fails.
        try:
            for operation in (self.close_server, self.stop_local_processes, self.export_final,
                              self.capture_usage, self.cleanup):
                try:
                    operation()
                except BaseException as exc:
                    errors.append(exc)
        finally:
            self._resources.close()  # Credential copies are owned from their creation onward.
        self.result("cleanup-local-processes", not children_by_home(str(self.home)), "No isolated runtime processes remain")
        self.result("cleanup-private-files", not self.temp.exists(), "Temporary QA credentials/state removed")
        self.save()
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hook", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--usage-db", type=Path)
    args = parser.parse_args()
    if args.hook:
        hook_main()
        return
    if not args.output or not args.usage_db:
        parser.error("--output and --usage-db required")
    suite = ManagedSuite(args.output)
    suite.usage_db = args.usage_db
    try:
        suite.bridge()
        suite.execute()
    except Exception as exc:
        suite.result("execution", False, suite.clean(str(exc)))
        raise
    finally:
        suite.finish()
    print(suite.run, "turns", suite.turns, "provider calls", suite.observed_calls)
    return int(any(row["status"] != "PASS" for row in suite.results))


if __name__ == "__main__":
    raise SystemExit(main())
