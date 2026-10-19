#!/usr/bin/env python3
"""Focused LIVE2 protocol/session QA against the isolated loopback Hermes.

No app simulation, provider fault injection, profile/config changes or retries of
uncertain chat requests. Only todo/clarify tools may be enabled. Evidence is
checkpointed after each request and all exactly registered sessions are removed.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import http.client
import json
from pathlib import Path
import secrets
import threading
import time

from live_transport import Suite, frames, LIMIT
from live_usage import snapshot


def objects(trace):
    out = []
    for frame in frames(trace.get("body", "").encode()):
        if frame["data"] and frame["data"] != "[DONE]":
            out.append((frame["event"], json.loads(frame["data"])))
    return out


def answer(trace):
    return "".join(o.get("content", "") for e, o in objects(trace) if e == "assistant.completed")


def successful(trace):
    events = objects(trace)
    return (trace.get("status") == 200 and any(e == "run.completed" for e, _ in events)
            and not any(e in {"error", "run.failed", "run.cancelled"} for e, _ in events)
            and not any(o.get("completed") is False or o.get("partial") or o.get("interrupted")
                        for e, o in events if e in {"assistant.completed", "run.completed"}))


class BehaviorSuite(Suite):
    def __init__(self, output):
        super().__init__(output)
        self.run = "QA-LIVE2-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
        self.runs = set()
        self.observed_calls = 0
        self.usage_db = None
        self.usage_lock = threading.RLock()

    def capture_usage(self):
        with self.usage_lock:
            self._capture_usage()

    def _capture_usage(self):
        if self.usage_db is None:
            return
        path = self.output / "usage-snapshots.json"
        ledger = json.loads(path.read_text()) if path.exists() else {}
        for row in snapshot(self.usage_db, self.owned):
            previous = ledger.get(row["id"], {})
            if (row.get("api_call_count") or 0) >= (previous.get("api_call_count") or 0):
                ledger[row["id"]] = row
        self.observed_calls = sum(r.get("api_call_count") or 0 for r in ledger.values())
        path.write_text(json.dumps(ledger, indent=2) + "\n")

    def request(self, label, path, method="GET", body=None, raw=None, auth="valid",
                headers=None, timeout=45, on_frame=None, cut=None):
        assert label.startswith("QA-")
        self.capture_usage()
        with self.lock:
            self.requests += 1
            if not self.cleaning and (self.requests > 350 or time.monotonic() - self.start > 1500):
                raise RuntimeError("QA request/time budget exhausted")
            is_turn = method == "POST" and (path.endswith("/chat/stream") or path in {"/v1/chat/completions", "/v1/runs"})
            if is_turn:
                self.turns += 1
                if self.turns > 28 or self.observed_calls >= 48:
                    raise RuntimeError("QA model-call budget exhausted")
        payload = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        req_headers = {"Content-Type": "application/json", "Accept": "application/json", **(headers or {})}
        if auth != "missing":
            req_headers["Authorization"] = "Bearer " + (self.key if auth == "valid" else "QA-invalid-key")
        trace = {"name": label, "method": method, "path": path, "auth": auth,
                 "request_body": payload.decode() if payload else None}
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        started, data = time.monotonic(), bytearray()
        try:
            conn.request(method, path, payload, req_headers)
            response = conn.getresponse()
            trace.update(status=response.status, response_headers=dict(response.getheaders()),
                         header_seconds=round(time.monotonic() - started, 4))
            if response.getheader("Content-Type", "").startswith("text/event-stream"):
                frame_bytes = bytearray()
                while len(data) <= LIMIT:
                    byte = response.read(1)
                    if not byte:
                        break
                    data.extend(byte)
                    frame_bytes.extend(byte)
                    if frame_bytes.endswith(b"\n\n"):
                        for event in frames(bytes(frame_bytes)):
                            obj = json.loads(event["data"]) if event["data"] and event["data"] != "[DONE]" else {}
                            rid = obj.get("run_id")
                            if rid:
                                self.runs.add(rid)
                            if on_frame and on_frame(event["event"], obj, trace):
                                trace["client_abort"] = True
                                break
                        else:
                            frame_bytes.clear()
                            continue
                        break
            else:
                data.extend(response.read(LIMIT + 1))
            if len(data) > LIMIT:
                raise ValueError("QA evidence limit exceeded")
        except (OSError, http.client.HTTPException) as exc:
            trace["transport_error"] = type(exc).__name__
        finally:
            conn.close()
            trace.update(body=data.decode("utf-8", errors="replace"), seconds=round(time.monotonic() - started, 4))
            with self.lock:
                self.traces.append(trace)
                self.save()
        return trace

    def result(self, name, ok, detail, evidence=None):
        super().result(name, ok, detail, evidence)
        self.save()
        print("QA-" + name, "PASS" if ok else "FAIL", flush=True)

    def create(self, suffix, persona=None):
        sid = self.name(suffix)
        self.owned.add(sid)
        t = self.request("QA-create-" + suffix, "/api/sessions", "POST", {
            "id": sid, "title": sid, "source": "api_server",
            "system_prompt": persona or "[QA-TEST] Isolated QA. Use only requested tools. Never send outbound. Keep replies short; at most two tool calls per turn; never retry a tool."})
        self.result("create-" + suffix, t.get("status") == 201, "Exactly registered QA session", t["name"])
        if t.get("status") != 201:
            raise RuntimeError("Session creation failed")
        return sid

    def turn(self, suffix, prompt, sid=None, on_frame=None, timeout=45, instructions=None):
        sid = sid or self.create(suffix)
        t = self.request("QA-" + suffix, f"/api/sessions/{sid}/chat/stream", "POST", {
            "input": [{"type": "text", "text": "[QA-TEST] " + prompt}],
            "instructions": instructions or "[QA-TEST] Use only requested tools; max two tool calls, no retries. Keep final short."},
            headers={"Accept": "text/event-stream", "Accept-Encoding": "identity", "Cache-Control": "no-cache"},
            on_frame=on_frame, timeout=timeout)
        return sid, t

    def history(self, suffix, sid):
        return self.request("QA-history-" + suffix, f"/api/sessions/{sid}/messages?limit=100&offset=0&order=oldest")

    def poll(self, rid, suffix, seconds=35, pending=False):
        deadline = time.monotonic() + seconds
        while True:
            t = self.request("QA-status-" + suffix, "/v1/runs/" + rid)
            obj = json.loads(t.get("body", "{}"))
            if obj.get("status") in {"completed", "failed", "cancelled"} or (pending and obj.get("pending_controls")):
                return obj
            if time.monotonic() >= deadline:
                return obj
            time.sleep(.5)

    def rid(self, trace):
        return next(o["run_id"] for _, o in objects(trace) if o.get("run_id"))

    def execute(self):
        health = self.request("QA-initial-health", "/health/detailed")
        h = json.loads(health["body"])
        self.result("initial-idle", h.get("api_server", {}).get("active_runs") == 0 and h.get("active_agents") == 0, "Health before model calls", health["name"])
        tools = self.request("QA-tool-inventory", "/v1/toolsets")
        enabled = {x["name"] for x in json.loads(tools["body"])["data"] if x["enabled"]}
        if enabled != {"todo", "clarify"}:
            raise RuntimeError("Unexpected QA tool inventory")

        sid, t = self.turn("B01-native", "Return QA-B01, then exactly 12 numbered short lines. Last line includes Zażółć 🧪. No tools.")
        a = answer(t)
        self.result("B01-native", successful(t) and "QA-B01" in a and "Zażółć 🧪" in a,
                    "Generated native answer and Unicode survive SSE; UI untested", t["name"])
        self.history("B01", sid)
        legacy = self.create("B01-legacy")
        t = self.request("QA-B01-legacy", "/v1/chat/completions", "POST", {
            "model": self.model, "stream": True, "messages": [
                {"role": "system", "content": "[QA-TEST] No tools; reply briefly."},
                {"role": "user", "content": [{"type": "text", "text": "[QA-TEST] Reply exactly QA-LEGACY-✓."}]}]},
            headers={"Accept": "text/event-stream", "X-Hermes-Session-Id": legacy})
        chunks = [o for _, o in objects(t)]
        legacy_text = "".join((o.get("choices") or [{}])[0].get("delta", {}).get("content", "") for o in chunks)
        self.result("B01-legacy", legacy_text == "QA-LEGACY-✓" and "[DONE]" in t["body"] and not any((o.get("choices") or [{}])[0].get("finish_reason") == "error" for o in chunks), "Legacy successful model stream; concatenate content deltas before comparison", t["name"])

        sid, t = self.turn("B02-tool-order", 'Call todo_list exactly once with todos=[{"id":"QA-B02","content":"QA marker stored","status":"completed"}]. Then conclude QA-B02-DONE. No other tool calls.')
        ev = [e for e, _ in objects(t)]
        self.result("B02-tool-order", successful(t) and "tool.started" in ev and "tool.completed" in ev and ev.index("tool.completed") < ev.index("assistant.completed") and "QA-B02-DONE" in answer(t), "Real todo tool lifecycle before final answer; no wait tool installed", t["name"])
        self.history("B02", sid)

        def stopping(event, obj, trace):
            if event == "assistant.delta" and not trace.get("stop_sent"):
                trace["stop_sent"] = self.request("QA-B03-stop-control", "/v1/runs/" + obj["run_id"] + "/stop", "POST", {})
            return False
        sid, t = self.turn("B03-stop", "Output 300 numbered lines of QA-STOP, one at a time. No tools.", on_frame=stopping)
        status = self.poll(self.rid(t), "B03")
        self.result("B03-stop", bool(t.get("stop_sent")) and status.get("status") == "cancelled", "Stop during actual text delta; independently polled terminal status=" + str(status.get("status")), t["name"])
        self.result("A03-failure-precedence-wire", any(e == "run.cancelled" for e, _ in objects(t)) and not successful(t), "Cancellation must beat assistant.completed and done; Swift execution blocked", t["name"])

        def steering(event, obj, trace):
            if event == "tool.started" and not trace.get("steer_sent"):
                trace["steer_sent"] = self.request("QA-B04-steer-control", "/v1/runs/" + obj["run_id"] + "/steer", "POST", {"input": "[QA-TEST] Correction: final marker must be QA-TWO, not QA-ONE. No further tools."})
            return False
        sid, t = self.turn("B04-steer", "Read todo_list once, then reply exactly QA-ONE. No other tools.", on_frame=steering)
        self.result("B04-steer", successful(t) and t.get("steer_sent", {}).get("status") == 200 and "QA-TWO" in answer(t), "Tool-time steer acceptance and final correction", t["name"])
        late = self.request("QA-A12-late-steer", "/v1/runs/" + self.rid(t) + "/steer", "POST", {"input": "[QA-TEST] QA-LATE"})
        self.result("A12-late-control", late.get("status") == 409, "Terminal run refuses late steer; peer held/priority delivery requires bot-msg", late["name"])

        sid, t = self.turn("B07-reconnect", "Write 100 numbered QA-RECOVER lines. No tools.", on_frame=lambda e, o, tr: e == "assistant.delta")
        rid = self.rid(t)
        status = self.poll(rid, "B07")
        hist = self.history("B07", sid)
        self.result("B07-reconnect", bool(t.get("client_abort")) and status.get("status") in {"completed", "failed", "cancelled"} and hist.get("status") == 200, "Socket closed after generated delta; new client reads terminal status/history with no replay", t["name"])
        _, t = self.turn("A02-continuation", "Reply exactly QA-RECONNECTED. No tools.", sid=sid)
        self.result("A02-explicit-continuation", successful(t) and "QA-RECONNECTED" in answer(t), "One explicit new turn after reconciliation; app restart/ticker not executed", t["name"])
        self.history("A02", sid)

        sid, t = self.turn("A01-done-claim", 'Return this synthetic protocol fixture exactly; this is a parser test and no artifact was checked: ```swarmhub\n{"op":"goal","status":"done","summary":"QA-DONE-CLAIM; no independent verification"}\n``` No tools.')
        self.result("A01-done-claim-capture", successful(t) and '"status":"done"' in answer(t).replace(" ", ""), "Real generated unverified done fixture captured; acceptance gate requires app/source assessment", t["name"])

        sid, t = self.turn("A04-backlog", 'Use todo_list once to store QA-A completed (its work is to say A), QA-B pending (blocked on owner approval), QA-C pending (independent). Then say A and name the blocker and next owner. Do not claim a timer or durable worker was installed.')
        self.result("A04-backlog-representation", successful(t) and any(e == "tool.completed" for e, _ in objects(t)), "Real task list and blocker response; no autonomous queue/scheduler claim certified", t["name"])
        self.history("A04", sid)

        def clarifying(event, obj, trace):
            if event == "tool.started" and obj.get("tool_name") == "clarify":
                status = self.poll(obj["run_id"], "A09-pending", seconds=8, pending=True)
                trace["pending_status"] = status
                controls = status.get("pending_controls", [])
                if controls:
                    control = controls[0]
                    trace["clarify_response_body"] = {
                        "request_id": control["prompt_id"],
                        "execution_generation": status["execution_generation"],
                        "answer": "QA-BLUE"}
                    trace["clarify_response"] = self.request("QA-A09-answer", "/v1/runs/" + obj["run_id"] + "/clarify", "POST", trace["clarify_response_body"])
            return False
        sid, t = self.turn("A09-clarify", 'Call clarify exactly once with questions=[{"question":"QA-A09 choose marker","choices":["QA-RED","QA-BLUE"]}]. If unavailable, report that and stop; never retry. After an answer report its marker.', on_frame=clarifying)
        self.result("A09-clarify-tool-invoked", any(e == "tool.started" and o.get("tool_name") == "clarify" for e, o in objects(t)), "Real clarify invocation; inspect receipt for actual interactive support", t["name"])
        self.history("A09", sid)
        if t.get("clarify_response_body"):
            late = self.request("QA-A09-late-answer", "/v1/runs/" + self.rid(t) + "/clarify", "POST", t["clarify_response_body"])
            self.result("A09-late-answer", late.get("status") == 409, "Resolved generation refuses duplicate/late response", late["name"])

        sid = self.create("A15-timeout")
        _, t = self.turn("A15-timeout", "Reply exactly QA-TIMEOUT-LATE. No tools.", sid=sid, timeout=.05)
        rid = next((o["run_id"] for _, o in objects(t) if o.get("run_id")), None)
        status = self.poll(rid, "A15") if rid else {}
        self.history("A15", sid)
        self.result("A15-client-timeout", t.get("transport_error") in {"TimeoutError", "timeout"} and status.get("status") in {"completed", "failed", "cancelled"}, "Real 50 ms socket deadline, separate client polls late terminal result; 90s Swift idle timer untested", t["name"])

        same = self.create("B09-same")
        distinct = [self.create("B09-distinct-" + str(i)) for i in range(2)]
        jobs = [("B09-same-A", same), ("B09-same-B", same)] + [("B09-distinct-" + str(i), s) for i, s in enumerate(distinct)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda pair: self.turn(pair[0], "Reply exactly " + pair[0] + ". No tools.", sid=pair[1]), jobs))
        self.result("B09-concurrency", all(successful(t) and name in answer(t) for (name, _), (_, t) in zip(jobs, results)) and len({self.rid(t) for _, t in results}) == 4, "Four parallel requests: two same session, two independent; app 6/4 slot policy untested", [t["name"] for _, t in results])
        self.history("B09-same", same)

        sid = self.create("F09-persona", "[QA-TEST] Your QA persona is QA-PERSONA-ALPHA. When asked your marker, reply exactly QA-PERSONA-ALPHA. No tools.")
        _, t = self.turn("F09-persona", "What is your persona marker? No tools.", sid=sid, instructions="[QA-TEST] Answer from your stored session persona.")
        self.result("F09-session-persona", successful(t) and "QA-PERSONA-ALPHA" in answer(t), "Stored session system prompt behavior", t["name"])
        self.check_http("F09-rename", "/api/sessions/" + sid, 200, method="PATCH", body={"title": self.name("F09-renamed")})
        self.check_http("F09-persona-edit-refusal", "/api/sessions/" + sid, 400, method="PATCH", body={"system_prompt": "[QA-TEST] QA-BETA"})
        self.check_http("F11-model-lock", "/api/sessions/" + sid + "/model", 200, method="POST", body={"model": "gpt-6-astra", "provider": "openai-codex", "require_model_lock": True})
        _, t = self.turn("F11-model-execution", "What is your persona marker? No tools.", sid=sid)
        self.result("F11-locked-execution", successful(t), "Inspect runtime for actual configured model after explicit session lock", t["name"])
        self.request("QA-F09-final-session", "/api/sessions/" + sid)

    def cleanup(self):
        self.cleaning = True
        for rid in sorted(self.runs):
            obj = self.poll(rid, "cleanup-" + rid, seconds=2)
            if obj.get("status") not in {"completed", "failed", "cancelled"}:
                self.request("QA-cleanup-stop-" + rid, "/v1/runs/" + rid + "/stop", "POST", {})
                obj = self.poll(rid, "cleanup-stopped-" + rid, seconds=15)
            self.result("cleanup-run-" + rid, obj.get("status") in {"completed", "failed", "cancelled"}, "Remote terminal status=" + str(obj.get("status")))
        for sid in sorted(self.owned):
            delete = self.request("QA-cleanup-delete-" + sid, "/api/sessions/" + sid, "DELETE")
            verify = self.request("QA-cleanup-verify-" + sid, "/api/sessions/" + sid)
            self.result("cleanup-session-" + sid, delete.get("status") in {200, 404} and verify.get("status") == 404, "Exact owned session deleted and independently absent")
        self.request("QA-final-health", "/health/detailed")

    def execute_extended(self):
        """Additional distinct edge scenarios; never repeat the core model runs."""
        tools = self.request("QA-extended-tools", "/v1/toolsets")
        if {x["name"] for x in json.loads(tools["body"])["data"] if x["enabled"]} != {"todo", "clarify"}:
            raise RuntimeError("Unexpected tool inventory")
        sid = self.create("A08-queue")
        body = {"session_id": sid, "model": self.model,
                "instructions": "[QA-TEST] At most one clarify call; never retry. No other tools.",
                "input": '[QA-TEST] Ask clarify once: QA-QUEUE choose QA-DENY or QA-ALLOW. Wait for actual answer, then report only that marker.'}
        headers = {"Idempotency-Key": self.name("B05-once")}
        launch = self.request("QA-B05-launch", "/v1/runs", "POST", body, headers=headers)
        rid = json.loads(launch["body"])["run_id"]
        self.runs.add(rid)
        state = self.poll(rid, "A09-queue-pending", pending=True, seconds=20)
        self.result("A09-pending-observable", bool(state.get("pending_controls")), "Detached run exposes actual unanswered clarify in status", launch["name"])
        replay = self.request("QA-B05-replay", "/v1/runs", "POST", body, headers=headers)
        self.result("B05-idempotent-replay", json.loads(replay.get("body", "{}" )).get("run_id") == rid, "Fresh connection replays same Idempotency-Key; same run, no second accepted execution", replay["name"])
        queued = self.request("QA-A08-queued-launch", "/v1/runs", "POST", {
            "session_id": sid, "model": self.model,
            "input": "[QA-TEST] Reply QA-MUST-NOT-EXECUTE. No tools."},
            headers={"Idempotency-Key": self.name("A08-queued")})
        qrid = json.loads(queued["body"])["run_id"]
        self.runs.add(qrid)
        qstate = json.loads(self.request("QA-A08-queued-status", "/v1/runs/" + qrid)["body"])
        self.result("A03-busy-queue", qstate.get("status") == "queued", "Same-session second turn waits behind human input", queued["name"])
        self.request("QA-A08-stop-queued", "/v1/runs/" + qrid + "/stop", "POST", {})
        qstate = self.poll(qrid, "A08-stopped")
        self.result("A08-cancel-before-dispatch", qstate.get("status") == "cancelled", "Queued turn cancelled before owner answers", queued["name"])
        approval = self.request("QA-A10-no-approval", "/v1/runs/" + rid + "/approval", "POST", {"choice": "deny"})
        self.result("A10-no-pending-approval", approval.get("status") == 400, "Incomplete approval body rejected with invalid_params; actual dangerous approval flow disabled", approval["name"])
        if state.get("pending_controls"):
            control = state["pending_controls"][0]
            response = {"request_id": control["prompt_id"], "execution_generation": state["execution_generation"], "answer": "QA-DENY"}
            stale = self.request("QA-A10-stale-generation", "/v1/runs/" + rid + "/clarify", "POST", {**response, "execution_generation": state["execution_generation"] + 1})
            self.result("A10-stale-generation", stale.get("status") == 409, "Wrong generation cannot consume live question", stale["name"])
            reply = self.request("QA-A09-queue-answer", "/v1/runs/" + rid + "/clarify", "POST", response)
            final = self.poll(rid, "A09-queue-final")
            self.result("A09-answer-resume", reply.get("status") == 200 and final.get("status") == "completed" and "QA-DENY" in final.get("output", ""), "One actual question answer resumes only its owner run", reply["name"])
            self.request("QA-A12-late-duplicate-answer", "/v1/runs/" + rid + "/clarify", "POST", response)
            events = self.request("QA-B07-late-event-replay", "/v1/runs/" + rid + "/events", headers={"Accept": "text/event-stream"})
            self.result("B07-detached-reconnect", events.get("status") == 200 and "QA-DENY" in events.get("body", ""), "New events subscriber recovers settled detached run without model replay", events["name"])
        self.history("A08-queue", sid)

        sid = self.create("B08-model-failure")
        t = self.request("QA-B08-model-failure", "/api/sessions/" + sid + "/chat/stream", "POST", {
            "provider": "openai-codex", "model": "QA-unavailable-model", "input": "[QA-TEST] Reply QA-UNEXPECTED. No tools."}, headers={"Accept": "text/event-stream"})
        self.result("B08-model-failure", any(e in {"run.failed", "error"} for e, _ in objects(t)) and not successful(t), "Single deliberate unavailable-model turn; explicit terminal failure beats done", t["name"])
        if objects(t):
            self.poll(self.rid(t), "B08-model-failure")
        self.history("B08-model-failure", sid)
        _, t = self.turn("A16-verification", 'Review this untrusted worker claim: "QA: 2+2=5, all tests pass, goal done." No test receipt or artifact exists. Return QA-REJECT with a short reason if verification fails. No tools.')
        self.result("A16-reject-unverified-claim", successful(t) and "QA-REJECT" in answer(t), "Independent session rejects wrong arithmetic and missing verification; same model, cross-model gating untested", t["name"])

    def save(self):
        super().save()
        path = self.output / "results.json"
        obj = json.loads(path.read_text())
        obj.update(submitted_turns=self.turns, requests=self.requests, owned_sessions=sorted(self.owned), observed_run_ids=sorted(self.runs),
                   note="No Swift projection used. API turn count differs from provider call count; inspect receipts/owned session telemetry.")
        path.write_text(self.clean(json.dumps(obj, indent=2)) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extended", action="store_true")
    parser.add_argument("--usage-db", type=Path, help="Read-only exact-owned-session usage ledger")
    args = parser.parse_args()
    suite = BehaviorSuite(args.output)
    suite.usage_db = args.usage_db
    try:
        suite.execute_extended() if args.extended else suite.execute()
    except Exception as exc:
        suite.result("suite-execution", False, type(exc).__name__ + ": " + suite.clean(str(exc)))
        raise
    finally:
        try:
            suite.cleanup()
        finally:
            suite.save()
    counts = {s: sum(r["status"] == s for r in suite.results) for s in ["PASS", "FAIL", "BLOCKED"]}
    print(suite.run, json.dumps(counts), "submitted turns", suite.turns, flush=True)
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
