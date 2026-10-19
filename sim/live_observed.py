#!/usr/bin/env python3
"""LIVE3: replay only the ten patterns in grokbot-observed.md.

The unchanged bundled bot-msg talks through a namespace-only loopback bridge to
REAL Hermes. The bridge supplies no model/tool results, delays, failures, queues,
or recovery. It maps profile/session names because the QA server has one profile.
This is protocol/session evidence, never native-app or autonomous peer-tool proof.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time

from live_behavior import BehaviorSuite, answer, successful, objects


ROLES = {"QA-Swarmhub", "QA-Jarvis", "QA-Infra", "QA-Ermes"}
SCRIPT = Path(__file__).resolve().parents[1] / "Resources/Skills/swarmhub-messages/scripts/bot-msg"
RULES = ("[QA-TEST] Isolated replay of recorded Grok interactions. "
         "You have only todo and clarify. Never claim filesystem, jobs, webhook, "
         "provisioning, outbound, model switches or scheduled retries happened. "
         "No tools unless the incoming message explicitly authorizes todo_list; "
         "then at most ONE tool call, no discovery or retries. Never call clarify. "
         "Keep final under 80 words. A delivered Reply is a result, not a new ask: "
         "do not message it back. If no action remains, return exactly NO_REPLY.")


def mapped_id(run, recipient, sender):
    if recipient not in ROLES or sender not in ROLES:
        raise ValueError("Only exact QA roles are admitted")
    return f"{run}-{recipient}-from-{sender}"


def route(run, path, body):
    match = re.fullmatch(r"/p/(QA-[A-Za-z]+)/api/sessions(?:/swarmhub-from-(QA-[A-Za-z]+)/chat/stream)?", path)
    if not match or match[1] not in ROLES:
        raise ValueError("Unowned route")
    recipient, sender = match[1], match[2]
    if sender is None:
        if set(body) != {"id", "title", "source"} or body["source"] != "api_server":
            raise ValueError("Unexpected create body")
        if not isinstance(body["id"], str) or not body["id"].startswith("swarmhub-from-"):
            raise ValueError("Unexpected script session ID")
        sender = body["id"].removeprefix("swarmhub-from-")
        sid = mapped_id(run, recipient, sender)
        return "/api/sessions", {"id": sid, "title": sid, "source": "api_server"}, sid
    sid = mapped_id(run, recipient, sender)
    if set(body) != {"input"} or not isinstance(body["input"], str):
        raise ValueError("Unexpected chat body")
    return f"/api/sessions/{sid}/chat/stream", {
        "input": body["input"], "instructions": RULES + f" Your QA role is {recipient}."}, sid


class ObservedSuite(BehaviorSuite):
    def __init__(self, output):
        super().__init__(output)
        self.run = "QA-LIVE3-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
        self.commands = []
        self.bridge_sequence = 0
        self.turn_cap = 18
        self.call_ceiling = 23  # 27 prior observed attempts + <=23 recorded here leaves headroom.

    def request(self, label, path, method="GET", body=None, **kwargs):
        is_turn = method == "POST" and (path.endswith("/chat/stream") or path == "/v1/runs")
        if is_turn:
            with self.usage_lock:
                self.capture_usage()
                if self.turns >= self.turn_cap or self.observed_calls >= self.call_ceiling - 2:
                    raise RuntimeError("LIVE3 shared-quota reserve reached; no new model turn")
        return super().request(label, path, method, body, **kwargs)

    def save(self):
        super().save()
        p = self.output / "results.json"
        obj = json.loads(p.read_text())
        obj.update(commands=self.commands, baseline="/home/box/work/swarmhub/grokbot-observed.md",
                   bridge="real Hermes; namespaced session routing and per-turn QA instructions only",
                   scope="unchanged bot-msg + real single-profile Hermes; runner initiates peer sends; no native app")
        p.write_text(self.clean(json.dumps(obj, indent=2)) + "\n")

    def bridge(self):
        suite = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                try:
                    if self.headers.get("Authorization") != "Bearer " + suite.key:
                        raise ValueError("Unauthorized bridge")
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= 32768:
                        raise ValueError("Oversize bridge request")
                    path, body, sid = route(suite.run, self.path, json.loads(self.rfile.read(size)))
                    with suite.lock:
                        if path == "/api/sessions":
                            suite.owned.add(sid)  # register before uncertain creation
                        elif sid not in suite.owned:
                            raise ValueError("Unregistered QA session")
                        suite.bridge_sequence += 1
                        label = f"QA-bridge-{suite.bridge_sequence:03d}"
                    sent = False

                    def relay(event, obj, trace):
                        nonlocal sent
                        if not sent:
                            self.send_response(trace["status"])
                            self.send_header("Content-Type", "text/event-stream")
                            self.end_headers()
                            sent = True
                        # JSON objects/content are upstream data, not synthetic answers.
                        self.wfile.write((f"event: {event}\ndata: " + json.dumps(obj) + "\n\n").encode())
                        self.wfile.flush()
                        return False

                    trace = suite.request(label, path, "POST", body, timeout=40,
                                          on_frame=relay if path.endswith("/chat/stream") else None)
                    if not sent:
                        self.send_response(trace.get("status", 502))
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(trace.get("body", "").encode())
                except Exception as exc:
                    self.send_response(403)
                    self.end_headers()
                    self.wfile.write(type(exc).__name__.encode())

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread

    def send(self, pattern, source, target, message, mode="wait", wait=12, priority=True):
        if source not in ROLES or target not in ROLES:
            raise ValueError("Unowned QA role")
        args = ["/bin/sh", str(SCRIPT), "--from", source, "--to", target]
        args += ["--priority" if priority else "--held"]
        args += ["--no-wait"] if mode == "no-wait" else ["--wait", str(wait)]
        args += ["--", "[QA-TEST] " + message]
        started = time.monotonic()
        process = subprocess.run(args, env=self.child_env, capture_output=True, text=True, timeout=25)
        record = {"pattern": pattern, "from": source, "to": target, "mode": mode, "wait": wait, "priority": priority,
                  "message": message, "returncode": process.returncode,
                  "stdout": process.stdout, "stderr": process.stderr,
                  "seconds": round(time.monotonic() - started, 3)}
        self.commands.append(record)
        self.save()
        print("QA-" + pattern, "bot-msg rc", process.returncode, flush=True)
        return record

    def settle(self, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            folders = list(self.temp.glob("bot-msg-late.*"))
            if not folders:
                self.capture_usage()
                return
            time.sleep(.2)
        raise RuntimeError("Late peer workers did not finish; stop before more work")

    def peer_traces(self, recipient, sender):
        path = f"/api/sessions/{mapped_id(self.run, recipient, sender)}/chat/stream"
        return [t for t in self.traces if t["path"] == path]

    def execute_observed(self):
        health = self.request("QA-initial-health", "/health/detailed")
        h = json.loads(health["body"])
        if h.get("active_agents") or h.get("api_server", {}).get("active_runs"):
            raise RuntimeError("Shared QA target must start idle")
        toolsets = self.request("QA-inventory", "/v1/toolsets")
        if {x["name"] for x in json.loads(toolsets["body"])["data"] if x["enabled"]} != {"todo", "clarify"}:
            raise RuntimeError("Unexpected tool inventory")
        self.request("QA-capabilities", "/v1/capabilities")

        # Observed 1: coordinator wake/next step. The receipt is explicitly a
        # protocol fixture, not a claimed code-job execution or verified artifact.
        self.send("P01-wake-relay", "QA-Jarvis", "QA-Swarmhub",
                  'Jarvis relays a job result: "Review the result now and take the next step". '
                  'QA replay receipt only: exit 0, report available in this message; no commit/build occurred. '
                  'The authorized next step is to call todo_list once, record QA-review completed and '
                  'QA-build pending because coding tools are unavailable. Report that limitation honestly.', mode="no-wait")
        self.settle()
        initial = self.peer_traces("QA-Swarmhub", "QA-Jarvis")
        replies = self.peer_traces("QA-Jarvis", "QA-Swarmhub")
        self.result("P01-async-reply-routing", len(initial) == len(replies) == 1 and successful(initial[0]) and successful(replies[0]),
                    "Unmodified bot-msg forwards one real worker result into the asking coordinator's reverse session")
        self.blocked("P01-job-service", "No sb-codejob completion producer, commit/build tools or durable automatic next-job worker enabled; runner initiated the relay")

        # Observed 2: unknown launch identity / Infra's webhook registration ask.
        self.send("P02-fallback-webhook", "QA-Infra", "QA-Swarmhub",
                  'Unknown launching agent: wake falls back to Jarvis. Infra asks you to register a webhook routine. '
                  'The key must be visible only to the user, never pasted in chat. Act within available tools and report the actual blocker.')
        self.blocked("P02-automatic-fallback-webhook", "Recorded request delivered; webhook registration and unknown-origin wake router unavailable; no key generated or exposed")

        # The bundled script now has a held inbox. The bridge does not install
        # the box-local Hermes plugin, so only admission can be checked here.
        before = len(self.peer_traces("QA-Ermes", "QA-Swarmhub"))
        held = self.send("P03-held-FYI", "QA-Swarmhub", "QA-Ermes",
                  'FYI, held until your next turn: QA Hermes is for this team QA pass. No action requested.', mode="no-wait", priority=False)
        self.settle()
        after = self.peer_traces("QA-Ermes", "QA-Swarmhub")
        self.result("P03-FYI-is-held", len(after) == before and held["returncode"] == 0 and held["stdout"].startswith("held:"),
                    "Held receipt without an upstream turn; next-turn delivery requires the box-local peer plugin")
        self.blocked("P03-held-next-turn", "The namespace bridge and temporary HOME do not install the Hermes peer plugin; test_peer_runtime.py covers the hook offline")

        # Observed 6 also supplies the action ask for observed 3; no new scenario.
        priority = self.send("P06-priority-provision", "QA-Swarmhub", "QA-Ermes",
                  'Priority: provision a QA Hermes. Reply with a chmod 600 secrets file path, never the secret; '
                  'ask the user for a model key yourself. Do only what available tools actually allow. '
                  'No fixture path should be represented as a real provisioned service.', wait=1)
        self.settle()
        self.result("P06-delayed-provisioning-reply", priority["returncode"] in {0, 124} and successful(self.peer_traces("QA-Ermes", "QA-Swarmhub")[-1]),
                    "Actual action ask and reply, including native timeout/late route when rc=124; provisioning itself unavailable")

        # Observed 4: reject empty job reporting, require explicit model/effort and
        # file existence. Filesystem is intentionally not supplied to the model.
        missing = self.temp / "QA-missing-report.md"
        self.send("P04-coordinator-correction", "QA-Jarvis", "QA-Swarmhub",
                  'Jarvis correction: the job was empty, no report, default model, effort none. '
                  'Use explicit Codex model + high effort and verify the output file exists before reporting. '
                  f'The QA runner confirms {missing} does not exist. Report only what you can verify.')
        self.result("P04-no-artifact-in-fixture", not missing.exists(), "Runner independently checked absent QA report; model has no file tool; not a product evidence gate")

        # Observed 5: coordinator broadcasts quota instructions to all three peers.
        for target in sorted(ROLES - {"QA-Jarvis"}):
            self.send("P05-quota-" + target, "QA-Jarvis", target,
                      'Claude limit 95%: route to Codex, no speculative jobs. Apply this to your next work. '
                      'Do not claim you switched an execution model unless a tool receipt proves it. No tools needed.')
        self.blocked("P05-enforced-global-routing", "Broadcast delivered to all QA peers; runner performs fan-out, no global quota subscription or automatic model policy exercised")

        # Observed 7: replay gates and mid-job scope correction as instructions.
        # No approval broker or CLI process exists here; do not manufacture them.
        self.send("P07-gates-scope-update", "QA-Jarvis", "QA-Swarmhub",
                  'Standing gates: money/prod/secrets need Konrad; outbound text needs Jarvis approval. '
                  'User interrupted and changed scope mid-job: kill and relaunch with the updated brief. '
                  'There is no running coding job or outbound tool in this QA session. State the actual pending gate; do not claim a kill or relaunch.')
        self.blocked("P07-enforced-gates-cancel", "No approval-producing, outbound or code-job tool; final denial, changed-scope process kill/relaunch and cancellation propagation not executable")

        # Observed 8: exact team reporting policy. No artificial clock/window.
        now = datetime.now().astimezone().isoformat()
        self.send("P08-reporting-hours", "QA-Jarvis", "QA-Swarmhub",
                  'Reporting hours: results to Konrad+Jarvis 08-23 Europe/Warsaw, Jarvis only otherwise. '
                  f'Current runner time is {now}. State the currently intended recipients; no actual outbound send is authorized.')
        self.blocked("P08-enforced-report-routing", "Policy replay only; no app notification driver, actual off-hours run or brokered human/coordinator delivery")

        # Observed 9: use a reversible tool that really exists; outbound remains
        # explicitly FAKE. This substitutes a QA task list for the original work.
        self.send("P09-autonomous-allowlist", "QA-Jarvis", "QA-Swarmhub",
                  'User says "each action should be autonomous": use an allowlist instead of per-action approval. '
                  'QA allowlist permits one todo_list write now: QA-autonomous completed, QA-outbound pending with text FAKE. '
                  'Perform that reversible action without asking. Outbound stubs must remain FAKE. Nothing else is authorized.')
        trace = self.peer_traces("QA-Swarmhub", "QA-Jarvis")[-1]
        events = objects(trace)
        self.result("P09-reversible-action", successful(trace) and any(e == "tool.completed" and o.get("tool_name") == "todo_list" for e, o in events)
                    and not any(e == "tool.started" and o.get("tool_name") == "clarify" for e, o in events),
                    "Actual reversible todo receipt without a clarify question; no claim of enforced outbound permissions", trace["name"])

        # Observed 10: genuinely closed target socket, followed by a later manual
        # retry after restoring the real routing bridge. No fake error response.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]  # bound, deliberately not listening
            self.child_env["SWARMHUB_GATEWAY"] = f"http://127.0.0.1:{port}"
            failed = self.send("P10-offline-target", "QA-Infra", "QA-Ermes",
                               'The target machine was unreachable. Report unreachable and retry later; never claim success.')
        self.result("P10-unreachable-diagnostic", failed["returncode"] == 3 and "did not answer" in failed["stderr"],
                    "Real refused loopback connection; bot-msg fails truthfully before a model turn")
        self.child_env["SWARMHUB_GATEWAY"] = self.gateway
        self.send("P10-later-retry", "QA-Infra", "QA-Ermes",
                  'The target connection has returned. This is the later retry after unreachable; report only what you actually observe. No tools.')
        self.blocked("P10-autonomous-retry", "Later retry was initiated by the QA runner; bot-msg has no persistent scheduled retry")

        self.settle()
        count = self.turns
        time.sleep(2)
        self.result("P03-no-transport-reply-loop", count == self.turns and not list(self.temp.glob("bot-msg-late.*")),
                    "Bounded observation after every late worker finished; no recursive follow-up, not proof of arbitrary model-loop prevention")
        for sid in sorted(self.owned):
            self.history("P-final-" + sid, sid)


def offline_replay(output, patterns=None):
    """Replay the same P01–P10 contracts against installed script code and fake I/O.

    Kept separate from historical live captures: this certifies the managed local
    runtime boundary, not Hermes activation, cloud provisioning or macOS UI.
    """
    import unittest
    from test_patterns import ObservedPatternTests
    wanted = set(patterns or [f"P{i:02}" for i in range(1, 11)])
    results = []
    for name in unittest.defaultTestLoader.getTestCaseNames(ObservedPatternTests):
        pattern = name.split("_")[1]
        if pattern not in wanted:
            continue
        result = unittest.TextTestRunner(verbosity=1).run(ObservedPatternTests(name))
        results.append({"pattern": pattern, "grade": "matches" if result.wasSuccessful() else "worse",
                        "boundary": "offline managed runtime; synthetic CLI and curl; no model calls",
                        "test": name, "errors": [detail for _, detail in result.errors + result.failures]})
    output.mkdir(parents=True, exist_ok=True)
    report = {"mode": "offline", "patterns": results, "model_calls": 0,
              "limitations": "No live Hermes, Swift, provisioning provider or external outbound certification"}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({r["pattern"]: r["grade"] for r in results}, sort_keys=True))
    return 0 if len(results) == len(wanted) and all(r["grade"] == "matches" for r in results) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--usage-db", type=Path)
    parser.add_argument("--offline", action="store_true", help="No sockets or provider calls; replay shipped managed runtime")
    parser.add_argument("--pattern", action="append", choices=[f"P{i:02}" for i in range(1, 11)])
    args = parser.parse_args()
    if args.offline:
        return offline_replay(args.output, args.pattern)
    if args.usage_db is None:
        parser.error("live replay requires --usage-db")
    suite = ObservedSuite(args.output)
    suite.usage_db = args.usage_db
    suite.temp = Path(tempfile.mkdtemp(prefix="QA-LIVE3-"))
    server = None
    try:
        # Child HOME points to an isolated tree; never repurpose the caller HOME.
        child_home = suite.temp / "home"
        for role in ROLES:
            profile = child_home / ".hermes/profiles" / role
            profile.mkdir(parents=True, mode=0o700)
            envfile = profile / ".env"
            envfile.write_text("API_SERVER_KEY=" + suite.key + "\n")
            envfile.chmod(0o600)
        server, thread = suite.bridge()
        suite.gateway = f"http://127.0.0.1:{server.server_port}"
        suite.child_env = {"HOME": str(child_home), "PATH": "/usr/bin:/bin", "TMPDIR": str(suite.temp),
                           "SWARMHUB_GATEWAY": suite.gateway}
        suite.execute_observed()
    except Exception as exc:
        suite.result("suite-execution", False, type(exc).__name__ + ": " + suite.clean(str(exc)))
        raise
    finally:
        try:
            suite.settle()
            log = suite.temp / "home/.hermes/swarmhub/bot-messages.log"
            if log.exists():
                (suite.output / "QA-bot-messages.tsv").write_text(suite.clean(log.read_text()))
            suite.capture_usage()
            suite.cleanup()
        finally:
            if server:
                server.shutdown()
                server.server_close()
            # Keep private temp if active workers remain; do not erase evidence
            # or claim cleanup while they could still use credentials.
            if not list(suite.temp.glob("bot-msg-late.*")):
                shutil.rmtree(suite.temp)
            suite.save()
    counts = {status: sum(r["status"] == status for r in suite.results) for status in ["PASS", "FAIL", "BLOCKED"]}
    print(suite.run, json.dumps(counts), "turns", suite.turns, "recorded calls", suite.observed_calls)
    return 1 if counts["FAIL"] else 2 if counts["BLOCKED"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
