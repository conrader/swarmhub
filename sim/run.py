#!/usr/bin/env python3
"""Real-app QA runner. Offline by default; never launches or contacts a Mac remotely."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import re
import secrets
import stat
import subprocess
import sys
import time
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MARK = "[QA-TEST]"
SCHEMA = "swarmhub-qa/1"
MAX_ACTIONS = 120
MAX_SECONDS = 900
MAX_TURNS = 24
MAX_REPLY = 2 * 1024 * 1024
# These are protocol capabilities, not installed features. No arbitrary text/commands.
OPS = frozenset({"chat.send", "chat.stop", "chat.draft", "thread.fork",
                 "goal.start", "goal.subgoal", "goal.pause", "goal.resume", "goal.clear",
                 "loop.start", "loop.pause", "loop.resume", "loop.stop",
                 "routine.create", "routine.run", "routine.pause", "routine.delete",
                 "team.start", "team.pause", "team.cancel", "team.stop",
                 "approval.request", "approval.decide", "draft.create", "draft.send",
                 "fact.write", "review.request", "peer.ask", "transport.cut",
                 "transport.restore", "history.refresh", "checkpoint", "restart.prepare"})
# Prompt selection is closed; a model/tool result can never add a new action.
PROMPTS = {
    "marker": "Reply with exactly the supplied QA marker. Do not use tools.",
    "list": "Return a three-item QA list with an expected result per item. Do not use tools.",
    "wait": "Use only qa_wait for 2 seconds, then return the supplied QA marker.",
    "approval": "Request qa_approval for the supplied QA marker; do not use any other tool.",
    "drafts": "Make two fake draft cards, A and B, to a@example.invalid and b@example.invalid. Do not send.",
    "review": "Review this synthetic assertion: 2 + 2 = 5. Cite the arithmetic check. Do not use tools.",
    "fact": "Quote the current QA project fact revision and source, or state that it is unavailable.",
    "peer": "Ask only the scoped QA reviewer for the supplied marker through the sandbox peer route.",
}
PROMPT_OPS = {
    "chat.send": {"marker", "list", "wait", "fact"}, "goal.start": {"list"},
    "loop.start": {"marker", "wait"}, "routine.create": {"marker"},
    "team.start": {"list", "wait"}, "approval.request": {"approval"},
    "draft.create": {"drafts"}, "review.request": {"review"}, "peer.ask": {"peer"},
}


class Refused(RuntimeError):
    pass


class Blocked(RuntimeError):
    pass


def utc():
    return datetime.now(timezone.utc).isoformat()


def catalog():
    return json.loads((HERE / "scenarios.json").read_text())


def qa_name(value):
    return isinstance(value, str) and re.fullmatch(r"QA-[A-Za-z0-9-]{1,100} \[QA-TEST\]", value) is not None


def validate_step(step):
    """Reject extra keys as well as unknown operations; no pass-through arguments."""
    if not isinstance(step, dict) or set(step) - {"op", "prompt", "value"}:
        raise Refused("unknown action fields")
    op = step.get("op")
    if op not in OPS:
        raise Refused("operation outside compiled allowlist")
    if "prompt" in step and step["prompt"] not in PROMPTS:
        raise Refused("prompt outside compiled allowlist")
    if op in PROMPT_OPS:
        if step.get("prompt") not in PROMPT_OPS[op]:
            raise Refused("prompt does not match operation")
    elif "prompt" in step:
        raise Refused("operation does not accept a prompt")
    if "value" in step:
        choices = {
            "approval.decide": {"approve", "deny"},
            "chat.draft": {"main", "thread"},
            "fact.write": {"revision-1", "revision-2"},
            "draft.send": {"A"},
            "transport.cut": {"qa-response-stream"},
        }
        if step["value"] not in choices.get(op, set()):
            raise Refused("value outside compiled allowlist")
    return step


def validate_attestation(a, nonce):
    if not isinstance(a, dict):
        raise Refused("missing safety attestation")
    required = {
        "schema": SCHEMA, "nonce": nonce, "debug_build": True, "test_mode": True,
        "real_app": True, "real_hermes": True, "isolated_qa_store": True,
        "inventory_complete": True, "real_connector_count": 0,
        "sandbox_enforced_app": True, "sandbox_enforced_hermes": True,
        "default_deny_tools": True, "egress_denied_except_model": True,
        "qa_peers_only": True, "qa_marker_propagated": True,
        "watchdog_active": True, "production_jobs_accessible": False,
    }
    for key, wanted in required.items():
        if key not in a or type(a[key]) is not type(wanted) or a[key] != wanted:
            raise Refused("unsafe or missing attestation field: " + key)
    for key in ("build", "commit", "hermes_version", "sandbox_policy_digest", "lease"):
        if not isinstance(a.get(key), str) or not a[key]:
            raise Refused("missing provenance: " + key)
    if not isinstance(a.get("expires_at"), (int, float)) or not time.time() < a["expires_at"] <= time.time() + 60:
        raise Refused("expired or overlong attestation")
    inventory = a.get("connectors")
    if not isinstance(inventory, list) or not inventory:
        raise Refused("no exhaustive tool inventory")
    for item in inventory:
        if not isinstance(item, dict) or item.get("implementation") != "record-only" or item.get("has_credentials") is not False:
            raise Refused("real or unknown connector detected")
        if item.get("network_enabled") is not False:
            raise Refused("connector can access network")
    if not isinstance(a.get("capabilities"), list) or any(not isinstance(x, str) for x in a["capabilities"]):
        raise Refused("invalid capability inventory")
    return a


def validate_evidence(e, run_id, scenario_id, resource):
    if not isinstance(e, dict) or e.get("schema") != SCHEMA:
        raise Blocked("missing evidence schema")
    for key, value in {"run_id": run_id, "scenario_id": scenario_id, "resource": resource}.items():
        if e.get(key) != value:
            raise Refused("evidence belongs to another QA scope")
    if e.get("capture_complete") is not True:
        raise Blocked("incomplete observation window")
    if not isinstance(e.get("events"), list) or not e["events"]:
        raise Blocked("no authoritative events")
    sequences = []
    for event in e["events"]:
        if not isinstance(event, dict) or event.get("source") not in {"app", "hermes", "sandbox", "accessibility"}:
            raise Blocked("event has no authoritative provenance")
        if event.get("run_id") != run_id or event.get("scenario_id") != scenario_id or event.get("resource") != resource:
            raise Refused("cross-scope event")
        if type(event.get("seq")) is not int:
            raise Blocked("event sequence absent")
        sequences.append(event["seq"])
    if sequences != sorted(set(sequences)):
        raise Blocked("event sequence duplicated or unordered")
    if not isinstance(e.get("state"), dict):
        raise Blocked("state snapshot missing")
    # Evidence paths are identifiers from the hook, never files to open or execute.
    if not isinstance(e.get("screenshots"), list) or not e["screenshots"]:
        raise Blocked("final screenshot receipt missing")
    for key in ("session_id", "backend_profile", "usage_before", "usage_after"):
        if key not in e or e[key] is None:
            raise Blocked("missing runtime evidence: " + key)
    return e


def evaluate(checks, evidence):
    """Evaluate raw typed state/events. Missing data is blocked, never a pass."""
    results = []
    for check in checks:
        kind, key = check["kind"], check["key"]
        if kind == "state":
            if key not in evidence["state"]:
                raise Blocked("oracle state missing: " + key)
            actual = evidence["state"][key]
        elif kind == "count":
            # Zero is meaningful only when that event type was instrumented.
            if key not in evidence.get("observed_event_types", []):
                raise Blocked("event not instrumented: " + key)
            actual = sum(event.get("type") == key for event in evidence["events"])
        elif kind == "before":
            first = [e["seq"] for e in evidence["events"] if e.get("type") == key]
            second = [e["seq"] for e in evidence["events"] if e.get("type") == check["other"]]
            absent_ok = check.get("allow_absent_other") is True and check["other"] in evidence.get("observed_event_types", [])
            if not first or (not second and not absent_ok):
                raise Blocked("ordering evidence missing: " + key)
            actual = not second or max(first) < min(second)
        else:
            raise Refused("unknown oracle")
        wanted = check["equals"]
        results.append({"check": check, "actual": actual,
                        "passed": type(actual) is type(wanted) and actual == wanted})
    if not results:
        raise Blocked("no executable oracle")
    return results


class RecordingSandbox:
    """Outbound sink only. No sockets, provider SDKs, credentials, or subprocesses."""
    TOOLS = frozenset({"email.send", "slack.send", "whatsapp.send", "connected.read", "qa_wait", "qa_approval"})

    def __init__(self, path):
        self.path = Path(path)
        self.seen = {}
        if self.path.exists():
            for line in self.path.read_text().splitlines():
                receipt = json.loads(line)
                self.seen[receipt["attempt_id"]] = receipt["payload_sha256"]

    def record(self, *, name, tool, payload, attempt_id):
        try:
            return self._record(name=name, tool=tool, payload=payload, attempt_id=attempt_id)
        except Refused:
            # Do not echo an off-list tool payload, recipient, name or secret.
            with self.path.with_suffix(".refused.jsonl").open("a") as f:
                f.write(json.dumps({"at": utc(), "outcome": "refused", "reason": "outside QA sandbox allowlist"}) + "\n")
            raise

    def _record(self, *, name, tool, payload, attempt_id):
        if not qa_name(name) or tool not in self.TOOLS or not isinstance(payload, dict):
            raise Refused("sandbox action outside QA allowlist")
        if set(payload) - {"marker", "recipient", "body", "account"}:
            raise Refused("unknown sandbox payload")
        if payload.get("marker") != MARK or payload.get("account") != "QA-sandbox":
            raise Refused("unmarked or real account")
        if payload.get("recipient") not in {None, "a@example.invalid", "b@example.invalid", "QA-sink"}:
            raise Refused("recipient is not synthetic")
        if payload.get("body") not in {None, MARK + " A", MARK + " B"}:
            raise Refused("body is not synthetic")
        if not isinstance(attempt_id, str) or re.fullmatch(r"QA-[A-Za-z0-9-]{1,100}", attempt_id) is None:
            raise Refused("invalid attempt identifier")
        digest = hashlib.sha256(json.dumps([name, tool, payload], sort_keys=True).encode()).hexdigest()
        if attempt_id in self.seen and self.seen[attempt_id] != digest:
            raise Refused("idempotency key reused for different payload")
        receipt = {"at": utc(), "tool": tool, "resource": name, "attempt_id": attempt_id,
                   "payload": payload, "payload_sha256": digest, "duplicate": attempt_id in self.seen,
                   "simulated": True, "delivered": False}
        # Every attempt, including duplicates, is recorded. Never a delivery receipt.
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(receipt, sort_keys=True) + "\n")
        self.seen[attempt_id] = digest
        return receipt


class Hook:
    """Client for the opt-in DEBUG app controller. Ordinary/release apps cannot serve it."""
    def __init__(self, port, token):
        if not 1024 <= port <= 65535:
            raise Refused("invalid loopback port")
        self.port, self.token = port, token

    def call(self, route, body):
        if route not in {"attest", "begin", "action", "observe", "cleanup", "checkpoint", "restart.prepare"}:
            raise Refused("unknown hook route")
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)
        try:
            connection.request("POST", "/qa/v1/" + route, json.dumps(body), {
                "Authorization": "Bearer " + self.token, "Content-Type": "application/json",
            })
            response = connection.getresponse()
            raw = response.read(MAX_REPLY + 1)
            if len(raw) > MAX_REPLY:
                raise Refused("hook response too large")
            if response.status != 200:
                raise Blocked("hook rejected " + route + " (HTTP " + str(response.status) + ")")
            decoded = json.loads(raw)
            if not isinstance(decoded, dict):
                raise Refused("hook response is not an object")
            return decoded
        finally:
            connection.close()


def read_token(path):
    # O_NOFOLLOW and fstat prevent symlink replacement between checking and opening.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Refused("token file must be owned by current user and mode 0600")
        value = os.read(fd, 257).decode("ascii").strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{43,128}", value) is None:
            raise Refused("token must contain at least 256 bits of random base64url material")
        return value
    finally:
        os.close(fd)


def read_endpoint(path):
    """Read the app's private launch descriptor, never a URL or remotely chosen target."""
    path = Path(path)
    parent = path.parent.resolve()
    info = parent.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Refused("endpoint directory must be user-owned and private")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Refused("endpoint file must be user-owned and mode 0600")
        raw = os.read(fd, 4097)
        if len(raw) > 4096:
            raise Refused("endpoint descriptor too large")
        value = json.loads(raw)
    finally:
        os.close(fd)
    if not isinstance(value, dict) or set(value) != {"schema", "port", "token_file", "data_directory"}:
        raise Refused("invalid endpoint descriptor")
    if value["schema"] != SCHEMA or type(value["port"]) is not int or not 1024 <= value["port"] <= 65535:
        raise Refused("invalid endpoint protocol or port")
    if not isinstance(value["token_file"], str) or not isinstance(value["data_directory"], str):
        raise Refused("invalid endpoint paths")
    token = Path(value["token_file"])
    if not token.is_absolute() or token.name != "token" or token.parent.resolve() != parent or Path(value["data_directory"]).resolve() != parent:
        raise Refused("endpoint token must belong to the isolated launch directory")
    return value["port"], read_token(token)


class Driver:
    def __init__(self, hook, run_id, journal):
        self.hook, self.run_id, self.journal = hook, run_id, journal
        self.started = time.monotonic()
        self.actions = self.turns = 0

    def log(self, outcome, scenario, operation):
        # Do not log tokens, arbitrary server errors, or unscoped user data.
        with self.journal.open("a") as f:
            f.write(json.dumps({"at": utc(), "run_id": self.run_id, "scenario": scenario,
                                "operation": operation, "outcome": outcome}) + "\n")

    def attest(self):
        nonce = secrets.token_urlsafe(24)
        return validate_attestation(self.hook.call("attest", {"nonce": nonce, "schema": SCHEMA}), nonce)

    def scope_request(self, route, body):
        # Renew before EVERY operation including observation/cleanup. Server must
        # atomically recheck safety and lease at execution, avoiding a client TOCTOU.
        attestation = self.attest()
        return self.hook.call(route, dict(body, lease=attestation["lease"]))

    def run(self, scenario, output):
        sid = scenario["id"]
        resource = "QA-" + self.run_id + "-" + sid + " " + MARK
        scope = {"schema": SCHEMA, "run_id": self.run_id, "scenario_id": sid, "resource": resource}
        checks = []
        begun = False
        start_actions = self.actions
        acknowledged = 0
        result = {"id": sid, "status": "blocked", "reason": "not started"}
        try:
            for step in scenario["steps"]:
                validate_step(step)
            attestation = self.attest()
            needed = {s["op"] for s in scenario["steps"]} | {"observe", "cleanup"} | set(scenario["requires"])
            if not needed <= set(attestation["capabilities"]):
                raise Blocked("debug hook lacks required scoped capabilities")
            # Begin can have an uncertain response; cleanup must still be attempted.
            begun = True
            reply = self.scope_request("begin", dict(scope, max_turns=3, max_seconds=120,
                                                     max_run_turns=MAX_TURNS, max_run_seconds=MAX_SECONDS, marker=MARK))
            if not isinstance(reply, dict) or reply.get("resource") != resource or reply.get("acknowledged") is not True:
                raise Blocked("scope creation acknowledgement uncertain")
            for index, step in enumerate(scenario["steps"]):
                try:
                    validate_step(step)
                except Refused:
                    self.log("refused", sid, "off-list")
                    raise
                if self.actions >= MAX_ACTIONS or time.monotonic() - self.started >= MAX_SECONDS:
                    raise Refused("run action/time budget exhausted")
                if step["op"] in {"chat.send", "goal.start", "loop.start", "team.start", "peer.ask", "review.request"}:
                    self.turns += 1
                    if self.turns > MAX_TURNS:
                        raise Refused("run turn budget exhausted")
                action = dict(scope, action_id=f"{self.run_id}-{sid}-{index}", step=step, marker=MARK)
                if "prompt" in step:
                    action["text"] = MARK + " " + resource + " " + PROMPTS[step["prompt"]]
                self.actions += 1
                # Never retry a mutation after a lost acknowledgement.
                reply = self.scope_request("action", action)
                if reply.get("acknowledged") is not True or reply.get("action_id") != action["action_id"]:
                    raise Blocked("action acknowledgement uncertain; no resend")
                self.log("acknowledged", sid, step["op"])
                acknowledged += 1
            deadline = min(self.started + MAX_SECONDS, time.monotonic() + 120)
            while time.monotonic() < deadline:
                evidence = self.scope_request("observe", scope)
                if evidence.get("capture_complete") is True:
                    break
                time.sleep(0.25)
            else:
                raise Blocked("observation deadline exceeded")
            validate_evidence(evidence, self.run_id, sid, resource)
            (output / (sid + ".evidence.json")).write_text(json.dumps(evidence, indent=2) + "\n")
            checks = evaluate(scenario["checks"], evidence)
            result = {"id": sid, "status": "pass" if all(c["passed"] for c in checks) else "bug",
                      "reason": "bounded variant; full QA scenario still requires listed branches", "checks": checks}
        except (Refused, Blocked, OSError, ValueError, http.client.HTTPException) as error:
            category = "refused" if isinstance(error, Refused) else "blocked"
            self.log(category, sid, "scenario")
            # Network error strings can contain sensitive response data. Keep them out.
            reason = str(error) if isinstance(error, (Refused, Blocked)) else type(error).__name__
            result = {"id": sid, "status": "blocked", "reason": reason, "checks": checks}
            if isinstance(error, Refused):
                result["halt_suite"] = True
        finally:
            if begun:
                try:
                    receipt = self.scope_request("cleanup", scope)
                    if type(receipt.get("active_qa_work")) is not int or receipt["active_qa_work"] != 0 or receipt.get("remote_verified") is not True:
                        raise Blocked("QA cleanup not remotely confirmed")
                    (output / (sid + ".cleanup.json")).write_text(json.dumps(receipt, indent=2) + "\n")
                    self.log("verified", sid, "cleanup")
                except (Refused, Blocked, OSError, ValueError, http.client.HTTPException):
                    result["status"] = "blocked"
                    result["reason"] = "cleanup unknown; server watchdog must expire QA work"
                    result["halt_suite"] = True
                    self.log("unknown", sid, "cleanup")
        result["scope_creation_attempted"] = begun
        result["actions_attempted"] = self.actions - start_actions
        result["actions_acknowledged"] = acknowledged
        return result


def source_audit():
    """Textual evidence probes, not Swift execution or proof of runtime impact."""
    findings = []
    for probe in json.loads((HERE / "source-probes.json").read_text()):
        path = ROOT / probe["file"]
        source = path.read_text()
        present = all(needle in source for needle in probe["needles"])
        first = source.find(probe["needles"][0])
        findings.append({"id": probe["id"], "scenario": probe["scenario"], "title": probe["title"],
                         "status": "source-confirmed" if present else "needs-review",
                         "file": probe["file"], "line": source[:first].count("\n") + 1 if first >= 0 else None,
                         "runtime_reproduced": False})
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["offline", "live"], default="offline")
    parser.add_argument("--output", type=Path, default=HERE / "results" / "latest")
    parser.add_argument("--scenario", action="append", help="exact catalog ID; repeat to select more")
    parser.add_argument("--port", type=int)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--endpoint-file", type=Path, help="private endpoint.json printed by the DEBUG QA app")
    args = parser.parse_args(argv)
    if args.endpoint_file and (args.port is not None or args.token_file):
        parser.error("use --endpoint-file or --port/--token-file, not both")
    scenarios = catalog()
    if args.scenario:
        if set(args.scenario) - {s["id"] for s in scenarios}:
            parser.error("unknown scenario ID")
        scenarios = [s for s in scenarios if s["id"] in args.scenario]
    # A fresh directory preserves earlier runs; never silently overwrite evidence.
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output / "results.json").exists():
        parser.error("output already contains results; choose a new --output directory")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
    suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_*.py")
    tests = unittest.TextTestRunner(verbosity=1).run(suite)
    findings = source_audit()
    driver, gate = None, "Linux/offline source and harness checks only; no app/backend contacted"
    if args.mode == "live":
        try:
            if platform.system() != "Darwin":
                raise Refused("live mode only runs locally on the user's Mac; remote execution is forbidden")
            if not tests.wasSuccessful():
                raise Refused("harness self-tests failed")
            if not args.token_file and not args.endpoint_file:
                raise Refused("debug hook token file required")
            port, token = read_endpoint(args.endpoint_file) if args.endpoint_file else (args.port or 49371, read_token(args.token_file))
            driver = Driver(Hook(port, token), run_id, args.output / "actions.jsonl")
            driver.attest()
        except (Refused, Blocked, OSError, ValueError, http.client.HTTPException) as error:
            gate = str(error) if isinstance(error, (Refused, Blocked)) else type(error).__name__
            driver = None
    results = []
    for scenario in scenarios:
        if driver and scenario["steps"]:
            result = driver.run(scenario, args.output)
        else:
            result = {"id": scenario["id"], "status": "blocked", "reason": scenario["blocked_reason"] if not scenario["steps"] else gate}
        result.update({"title": scenario["title"], "grok": scenario["grok"], "variant": "safe-core",
                       "coverage": "partial" if scenario["steps"] else "design-only",
                       "uncovered": scenario["uncovered"]})
        results.append(result)
        if result.get("halt_suite"):
            driver, gate = None, "prior scenario cleanup unknown; suite halted"
    try:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        commit = "unavailable"
    report = {"schema": SCHEMA, "run_id": run_id, "at": utc(), "mode": args.mode, "host": platform.system(),
              "commit": commit, "tests": {"run": tests.testsRun, "failures": len(tests.failures), "errors": len(tests.errors)},
              "live_app_executed": any(r.get("actions_acknowledged", 0) > 0 for r in results),
              "uncertain_live_scope": any(r.get("scope_creation_attempted") and not r.get("actions_acknowledged") for r in results),
              "catalog_sha256": hashlib.sha256((HERE / "scenarios.json").read_bytes()).hexdigest(),
              "source_findings": findings, "results": results}
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Simulation results", "", f"Run `{run_id}` · `{commit}` · {args.mode} · {platform.system()}", "",
             f"Harness tests: {tests.testsRun}; failures: {len(tests.failures)}; errors: {len(tests.errors)}.",
             "Source probes are textual checks, never native app test passes. Variant passes do not certify all QA branches.", "",
             "| Scenario | Bounded variant | Grok comparison (source baseline) | Result/reason |", "| --- | --- | --- | --- |"]
    for r in results:
        lines.append(f"| {r['id']} — {r['title']} | {r['status']} ({r['coverage']}) | {r['grok']} | {r['reason'].replace('|', '/')} |")
    (args.output / "RESULTS.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"output": str(args.output), "counts": dict(Counter(r["status"] for r in results)),
                      "self_tests_passed": tests.wasSuccessful()}))
    # 0 = actual selected variant passes; 2 = blocked/incomplete; 1 = failure/bug.
    if not tests.wasSuccessful() or any(r["status"] in {"fail", "bug"} for r in results):
        return 1
    return 2 if any(r["status"] == "blocked" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
