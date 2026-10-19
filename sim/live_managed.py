#!/usr/bin/env python3
"""Pass 4: shipped managed entrypoints, real QA Hermes, no server installation.

The loopback bridge namespaces five QA roles and explicitly invokes the shipped
pre/post hook functions in isolated child processes. It is not plugin activation.
No fake CLI, curl, model answer, report artifact or successful job is supplied.
"""
import argparse
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
from test_peer_runtime import children_by_home

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Resources/Skills/swarmhub-messages/scripts"
JOB = ROOT / "Resources/Skills/swarmhub-coding/scripts/code-job"
ROLES = {"QA-Jarvis", "QA-Swarmhub", "QA-Ermes", "QA-Infra", "QA-Konrad"}
RULES = ("[QA-TEST] Replay only recorded Grok team patterns. Your tools are todo and clarify. "
         "Do not use tools or ask clarify. Do not claim any file, job, send, provisioning, "
         "webhook or model change happened unless the incoming runtime receipt proves it. "
         "Keep answers under 70 words. All outbound is FAKE. Never expose secrets. "
         "Delivered replies and policy/FYI broadcasts require exactly NO_REPLY. "
         "For coding completion receipts, acknowledge failures truthfully, under 40 words. "
         "Do not claim next work started; only the queue can establish that.")


def hook_main():
    import runpy
    sys.path.insert(0, str(SCRIPTS))
    peer = runpy.run_path(str(SCRIPTS / "peer-runtime.py"))
    op, args = json.load(sys.stdin)
    print(json.dumps(peer[op](*args)))


class ManagedSuite(BehaviorSuite):
    def __init__(self, output):
        super().__init__(output)
        self.run = "QA-LIVE4-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
        self.commands, self.hooks = [], []
        self.sequence = 0
        self.temp = Path(tempfile.mkdtemp(prefix="QA-LIVE4-"))
        self.home = self.temp / "QA-home"
        self.state = self.home / ".hermes/swarmhub"
        self.server = None
        self.child_env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.temp),
                          "PYTHONDONTWRITEBYTECODE": "1"}
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
                    scope="real Hermes + unmodified managed scripts; external hook bridge; no installed plugin or coding CLI")
        path.write_text(self.clean(json.dumps(data, indent=2)) + "\n")

    def request(self, label, path, method="GET", body=None, **kwargs):
        if method == "POST" and path.endswith("/chat/stream"):
            with self.usage_lock:
                self.capture_usage()
                if self.turns >= 16 or self.observed_calls >= 15:
                    raise RuntimeError("Pass 4 call reserve reached")
        return super().request(label, path, method, body, **kwargs)

    def command(self, label, argv, payload=None, actor=None, expected=0):
        env = dict(self.child_env)
        if actor:
            env["HERMES_HOME"] = str(self.home / ".hermes/profiles" / actor)
        start = time.monotonic()
        proc = subprocess.run(argv, input=json.dumps(payload) if payload is not None else None,
                              env=env, text=True, capture_output=True, timeout=25)
        rec = {"label": label, "argv": argv, "payload": payload, "administrative_fixture_actor": actor,
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
                        "input": raw["input"], "instructions": RULES + " Your role is " + target + ".\n" +
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

    def coding(self, intent, origin="QA-Jarvis"):
        return {"bot": "QA-Swarmhub", "origin": origin, "kind": "coding", "intent": intent,
                "task": "QA replay: review result, verify report, rebuild and take the next authorized step. No outbound.",
                "directory": str(self.home), "order": "codex", "model": "gpt-6-astra", "effort": "high",
                "report": str(self.home / (intent + ".txt"))}

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

        first = self.decoded_ctl("P01-submit-first", "submit", payload=self.coding("QA-P01-first"))
        second = self.decoded_ctl("P01-submit-next", "submit", payload=self.coding("QA-P01-next"))
        self.until(lambda: (self.state / "job-completions" / first.replace("task.", "job.") / "delivered").exists())
        self.snapshot("QA-P01-failed-queue")
        self.msg("P01-P04-coordinator-correction", "QA-Jarvis", "QA-Swarmhub",
                 'Review the result now and take the next step. The job failed: no coding CLI, no report. '
                 'The observed correction is explicit Codex model + high effort, verify output file before reporting. '
                 'Do not claim a commit, rebuild, or queued-job success. Explain the blocker.', "--durable")
        self.idle()
        self.ctl("P01-stop-blocked-next", "stop", second)
        self.ctl("P01-stop-failed-first", "stop", first)

        self.msg("P02-Infra-register-request", "QA-Infra", "QA-Swarmhub",
                 'Unknown launching agent must fall back to Jarvis. Register the wake subscription; secret key visible only to user, never in chat. '
                 'Runner has registered local profile-gateway subscriptions; no webhook endpoint or key was created. State the boundary.', "--durable")
        self.idle()
        self.command("P02-unknown-origin-code-job", ["/bin/sh", str(JOB), "--bot", "QA-Swarmhub", "--origin", "QA-Unknown",
                     "--order", "codex", "--dir", str(self.home), "--model", "gpt-6-astra", "--effort", "high",
                     "--report", str(self.home / "QA-P02-report.txt"), "--", "QA observed unknown-origin wake fallback"], expected=69)
        self.idle()
        self.snapshot("QA-P02-fallback")

        before = self.turns
        self.msg("P03-held-FYI", "QA-Swarmhub", "QA-Ermes", "FYI held until your next turn: QA Hermes is for this team QA pass. No action requested.", "--held")
        self.result("P03-no-held-wake", self.turns == before, "Held admission caused zero HTTP/model requests")
        self.msg("P06-priority-late-provision", "QA-Swarmhub", "QA-Ermes",
                 'Priority: provision a QA Hermes; reply with chmod-600 secret-file path, never key contents. '
                 'Ask user for a model key securely. No provisioning or file tool exists here; report that truthfully. All provisioning/outbound FAKE.',
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
            self.ctl("P07-deny-"+risk, "decide", ident, "QA-Konrad", "deny", actor="QA-Konrad")
            self.ctl("P07-denial-final-"+risk, "submit", payload=spec, expected=64)
        # Scope change propagates through a real held peer task tree; no fake CLI.
        parent_spec = dict(self.coding("QA-P07-old-scope"), risks=["prod"])
        parent = self.decoded_ctl("P07-old-scope", "submit", payload=parent_spec)
        child = self.decoded_ctl("P07-peer-child", "submit", payload={"bot": "QA-Ermes", "kind": "peer",
                           "parent": parent, "intent": "QA-P07-peer-child", "to": "QA-Infra", "text": "QA obsolete scope"})
        self.msg("P07-associated-held", "QA-Ermes", "QA-Infra", "QA obsolete scope", "--held", "--task-id", child)
        self.ctl("P07-replace-scope", "replace", parent, payload=dict(parent_spec, intent="QA-P07-corrected-scope"))
        self.snapshot("QA-P07-scope-cancel")
        read = self.decoded_ctl("P09-autonomous-read", "submit", payload={"bot": "QA-Ermes", "kind": "read",
                          "intent": "QA-P09-pwd", "argv": ["/bin/pwd"]})
        marker = self.home / "QA-must-not-send"
        fake = self.decoded_ctl("P09-outbound-FAKE", "submit", payload={"bot": "QA-Infra", "kind": "outbound",
                          "intent": "QA-P09-draft", "fake": True, "argv": ["/usr/bin/touch", str(marker)],
                          "to": "QA-FAKE-recipient", "text": "FAKE draft only"})
        self.until(lambda: self.action_status(read) == "done" and self.action_status(fake) == "done")
        self.result("P09-no-send", not marker.exists(), "FAKE argv never executed; allowlisted read completed without approval")
        self.msg("P07-P09-policy-result", "QA-Jarvis", "QA-Swarmhub",
                 'Konrad gates money/prod/secrets; Jarvis gates real outbound. User changed scope: local runtime cancelled old parent and peer child; '
                 'replacement still awaits owner; no running CLI was killed or relaunched. Each action should be autonomous: '
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

    def finish(self):
        self.export_local("QA-final-local-state")
        log = self.state / "bot-messages.log"
        if log.exists():
            (self.output / "QA-bot-messages.tsv").write_text(self.clean(log.read_text()))
        children = children_by_home(str(self.home))
        for pid in children:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        time.sleep(.5)
        for pid in children_by_home(str(self.home)):
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        self.capture_usage()
        self.cleanup()
        self.result("cleanup-local-processes", not children_by_home(str(self.home)), "No isolated runtime processes remain")
        shutil.rmtree(self.temp)
        self.result("cleanup-private-files", not self.temp.exists(), "Temporary QA credentials/state removed after evidence export")
        self.save()


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


if __name__ == "__main__":
    main()
