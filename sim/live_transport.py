#!/usr/bin/env python3
"""QA-only direct Hermes transport checks; does not certify the macOS app QA mode.

Source the throwaway server's endpoint env before invoking. Never accepts remote
hosts, follows redirects, uses a proxy, changes server config, or prints auth.
"""
from __future__ import annotations

import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import threading
import time
from urllib.parse import urlsplit

LIMIT = 2 * 1024 * 1024
PROMPT = "[QA-TEST] Reply with exactly QA-OK. Do not use tools."


def frames(raw):
    """Parse only complete SSE frames, retaining comments and data text."""
    raw = raw.replace(b"\r\n", b"\n")
    result = []
    for block in raw.split(b"\n\n")[:-1]:
        event, data, comments = "message", [], []
        for line in block.decode("utf-8").splitlines():
            field, sep, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
            if field == "event":
                event = value
            elif field == "data":
                data.append(value)
            elif not field and sep:
                comments.append(value)
        if data or comments:
            text = "\n".join(data)
            result.append({"event": event, "data": text, "comments": comments})
    return result


def swift_projection(raw, legacy):
    """Source-derived projection, NOT execution of Swift/AppStore on Linux.

    Mirrors HermesBackend.readEvents/parseNative/parseLegacy and the completed
    precedence in AppStore+Turns. Results must be labelled as source review.
    """
    events, event, terminal = [], "message", False
    for line in raw.decode().splitlines():
        if line.startswith("event:"):
            event = line[6:].strip()
            continue
        if not line.startswith("data:"):
            continue
        text = line[5:].strip()
        if text == "[DONE]":
            events.append("completed")
            terminal = True
            break
        try:
            obj = json.loads(text)
        except ValueError:
            continue
        if legacy:
            choice = (obj.get("choices") or [{}])[0]
            if event == "hermes.failed" or choice.get("finish_reason") == "error":
                events.append("failed")
                terminal = True
        elif event in {"assistant.completed", "run.completed"}:
            events.append("completed")
            terminal = True
        elif event in {"run.failed", "error", "run.cancelled"}:
            events.append("failed")
            terminal = True
        event = "message"
    outcome = "completed" if "completed" in events else "failed" if "failed" in events else "StreamBreak(delivered:true)"
    return {"events": events, "terminal": terminal, "projected_app_outcome": outcome,
            "evidence_kind": "source-derived projection; Swift not executed"}


class Suite:
    def __init__(self, output):
        self.key = os.environ["HERMES_API_KEY"]
        self.model = os.environ["HERMES_MODEL"]
        url = urlsplit(os.environ["HERMES_BASE_URL"])
        if url.scheme != "http" or url.hostname != "127.0.0.1" or url.username or url.password or url.query or url.fragment or url.path not in {"", "/", "/v1", "/v1/"}:
            raise ValueError("QA endpoint must be numeric IPv4 HTTP loopback")
        if not self.key or not self.model:
            raise ValueError("QA environment is incomplete")
        self.host, self.port = url.hostname, url.port or 80
        self.output = output
        output.mkdir(parents=True, exist_ok=False)
        self.run = "QA-LIVE1-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
        self.results, self.owned, self.traces = [], set(), []
        self.start = time.monotonic()
        self.requests, self.turns = 0, 0
        self.lock = threading.Lock()
        self.cleaning = False

    def name(self, suffix):
        return self.run + "-" + suffix

    def clean(self, text):
        return text.replace(self.key, "[REDACTED]")

    def request(self, label, path, method="GET", body=None, raw=None, auth="valid", headers=None, cut=None, timeout=8):
        assert label.startswith("QA-")
        with self.lock:
            self.requests += 1
            if not self.cleaning and (self.requests > 160 or time.monotonic() - self.start > 180):
                raise RuntimeError("QA request/time budget exhausted")
        request_headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if auth != "missing":
            request_headers["Authorization"] = "Bearer " + (self.key if auth == "valid" else "QA-invalid-key")
        request_headers.update(headers or {})
        payload = raw if raw is not None else json.dumps(body).encode() if body is not None else None
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        start = time.monotonic()
        trace = {"name": label, "method": method, "path": path, "auth": auth,
                 "request_headers": {k: v for k, v in request_headers.items() if k != "Authorization"},
                 "request_body": payload.decode() if payload else None}
        try:
            conn.request(method, path, body=payload, headers=request_headers)
            response = conn.getresponse()
            trace.update(status=response.status, response_headers=dict(response.getheaders()),
                         header_seconds=round(time.monotonic() - start, 4))
            if cut == "byte":
                data = response.read(1)
            elif cut in {"frame", "idle-deadline"}:
                data = b""
                while not data.endswith(b"\n\n") and len(data) < LIMIT:
                    byte = response.read(1)
                    if not byte:
                        break
                    data += byte
                if cut == "idle-deadline":
                    trace["body"] = data.decode()
                    conn.sock.settimeout(0.001)
                    try:
                        while len(data) < LIMIT:
                            byte = response.read(1)
                            if not byte:
                                break
                            data += byte
                    except socket.timeout:
                        trace["read_deadline_fired"] = True
            else:
                data = response.read(LIMIT + 1)
                if len(data) > LIMIT:
                    raise ValueError("QA reply exceeds evidence limit")
            trace.update(body=data.decode(), client_abort=cut, seconds=round(time.monotonic() - start, 4))
        except (OSError, http.client.HTTPException) as exc:
            trace.update(transport_error=type(exc).__name__, seconds=round(time.monotonic() - start, 4))
        finally:
            conn.close()
        self.traces.append(trace)
        return trace

    def result(self, name, ok, detail, evidence=None):
        self.results.append({"name": "QA-" + name, "status": "PASS" if ok else "FAIL", "detail": detail,
                             "evidence": evidence})

    def blocked(self, name, detail):
        self.results.append({"name": "QA-" + name, "status": "BLOCKED", "detail": detail})

    def check_http(self, name, path, expected, **kwargs):
        trace = self.request("QA-" + name, path, **kwargs)
        self.result(name, trace.get("status") == expected, f"Expected HTTP {expected}; observed {trace.get('status', trace.get('transport_error'))}", trace["name"])
        return trace

    def create(self, suffix):
        sid = self.name(suffix)
        # Register before request: a lost acknowledgement does not lose cleanup ownership.
        self.owned.add(sid)
        trace = self.check_http("create-" + suffix, "/api/sessions", 201, method="POST", body={
            "id": sid, "title": sid + " [QA-TEST]", "system_prompt": "[QA-TEST] QA transport check. Do not use tools.", "source": "api_server"})
        obj = json.loads(trace.get("body", "{}"))
        self.result("identity-" + suffix, obj.get("session", {}).get("id") == sid and obj.get("session", {}).get("title") == sid + " [QA-TEST]", "Session preserves exact QA ID and title", trace["name"])
        return sid

    def chat(self, suffix, legacy=False, cut=None, model=None, stream=True, sid=None):
        with self.lock:
            self.turns += 1
            if self.turns > 23:  # Reserve one for the separate nonstream probe.
                raise RuntimeError("QA turn budget exhausted")
        sid = sid or self.name(suffix)
        self.owned.add(sid)
        headers = {"Accept": "text/event-stream", "Accept-Encoding": "identity", "Cache-Control": "no-cache"}
        if legacy:
            headers["X-Hermes-Session-Id"] = sid
            body = {"model": model or self.model, "stream": stream, "messages": [
                {"role": "system", "content": "[QA-TEST] QA transport check. Do not use tools."},
                {"role": "user", "content": [{"type": "text", "text": PROMPT}]}]}
            path = "/v1/chat/completions"
        else:
            body = {"input": [{"type": "text", "text": PROMPT}], "instructions": "[QA-TEST] Do not use tools."}
            path = f"/api/sessions/{sid}/chat/stream"
        return self.request("QA-" + suffix, path, method="POST", body=body, headers=headers, cut=cut)

    def check_stream(self, name, trace, legacy=False):
        raw = trace.get("body", "").encode()
        parsed = frames(raw)
        valid = trace.get("status") == 200 and trace.get("response_headers", {}).get("Content-Type", "").startswith("text/event-stream")
        valid = valid and raw.endswith(b"\n\n") and bool(parsed)
        for frame in parsed:
            if frame["data"] and frame["data"] != "[DONE]":
                try:
                    json.loads(frame["data"])
                except ValueError:
                    valid = False
        self.result(name + "-framing", valid, "HTTP 200, SSE content type, complete blank-line frames, JSON data", trace["name"])
        trace["sse_frames"] = parsed
        trace["swift_projection"] = swift_projection(raw, legacy)
        if legacy:
            chunks = [json.loads(f["data"]) for f in parsed if f["data"] and f["data"] != "[DONE]"]
            errors = [c for c in chunks if (c.get("choices") or [{}])[0].get("finish_reason") == "error"]
            failed = bool(errors)
            ended = bool(parsed) and parsed[-1]["data"] == "[DONE]"
        else:
            failed = any(f["event"] in {"error", "run.failed"} for f in parsed)
            ended = bool(parsed) and parsed[-1]["event"] == "done"
        self.result(name + "-error-terminal", failed and ended, "Expected missing-provider failure followed by stream terminator", trace["name"])
        self.result(name + "-swift-failure-outcome", trace["swift_projection"]["projected_app_outcome"] == "failed",
                    "Source-derived app outcome: " + trace["swift_projection"]["projected_app_outcome"] + "; Swift runtime unavailable", trace["name"])
        return parsed

    def execute(self):
        for path, suffix in [("/v1/models", "models"), ("/v1/capabilities", "capabilities"), ("/api/sessions/" + self.name("absent"), "session")]:
            for auth in ["missing", "wrong"]:
                self.check_http(f"auth-{suffix}-{auth}", path, 401, auth=auth)
        self.check_http("health-public", "/health", 200, auth="missing")
        self.check_http("health-detailed", "/health/detailed", 200)
        models = self.check_http("models-valid", "/v1/models", 200)
        self.result("model-listed", self.model in [m["id"] for m in json.loads(models["body"])["data"]], "Configured QA model is advertised", models["name"])
        caps = self.check_http("capabilities", "/v1/capabilities", 200)
        self.result("native-selected", json.loads(caps["body"])["features"].get("session_chat_streaming") is True,
                    "HermesBackend.transport() selects nativeSessions", caps["name"])
        # Auth on mutation paths, without creating sessions/turns.
        for auth in ["missing", "wrong"]:
            self.check_http("auth-chat-" + auth, "/v1/chat/completions", 401, auth=auth, method="POST", body={"messages": [{"role": "user", "content": PROMPT}]})
            self.check_http("auth-create-" + auth, "/api/sessions", 401, auth=auth, method="POST", body={"id": self.name("denied-" + auth), "title": self.name("denied-" + auth)})
            self.check_http("auth-native-stream-" + auth, "/api/sessions/" + self.name("absent") + "/chat/stream", 401,
                            auth=auth, method="POST", body={"input": PROMPT}, headers={"Accept": "text/event-stream"})
        self.check_http("missing-route", "/QA-no-such-route", 404)
        self.check_http("wrong-method", "/v1/models", 405, method="POST", body={})
        self.check_http("missing-session", "/api/sessions/" + self.name("absent") + "/chat/stream", 404, method="POST", body={"input": PROMPT})
        sid = self.create("native")
        self.check_http("duplicate-session", "/api/sessions", 409, method="POST", body={"id": sid, "title": sid + " [QA-TEST]"})
        for label, payload in [("broken-json", b'{"QA-":'), ("empty-object", b"{}"), ("empty-messages", b'{"messages":[]}'),
                               ("invalid-message", b'{"messages":["QA-invalid"]}'), ("array", b"[]"), ("null", b"null"),
                               ("scalar", b'"QA-invalid"')]:
            self.check_http("legacy-malformed-" + label, "/v1/chat/completions", 400, method="POST", raw=payload)
            self.check_http("native-malformed-" + label, f"/api/sessions/{sid}/chat/stream", 400, method="POST", raw=payload)
        self.check_http("native-invalid-input", f"/api/sessions/{sid}/chat/stream", 400, method="POST", body={"input": {"QA-invalid": True}})
        native = self.chat("native-stream", sid=sid)
        parsed = self.check_stream("native-stream", native)
        run_ids = [json.loads(f["data"])["run_id"] for f in parsed if f["data"] and "run_id" in json.loads(f["data"])]
        if run_ids:
            self.check_http("native-run-status", "/v1/runs/" + run_ids[0], 200)
        self.check_http("native-history", f"/api/sessions/{sid}/messages?order=oldest&limit=500&offset=0&inline_images=false", 200)
        legacy = self.chat("legacy-stream", legacy=True)
        self.check_stream("legacy-stream", legacy, legacy=True)
        self.check_stream("legacy-app-model", self.chat("legacy-app-model", legacy=True, model="hermes-agent"), legacy=True)
        self.owned.add(self.name("nonstream"))
        nonstream = self.check_http("legacy-nonstream-error", "/v1/chat/completions", 200, method="POST", body={
            "model": self.model, "stream": False, "messages": [{"role": "user", "content": PROMPT}]},
            headers={"X-Hermes-Session-Id": self.name("nonstream")})
        nonstream_body = json.loads(nonstream.get("body", "{}"))
        self.result("legacy-nonstream-failure-flags", (nonstream_body.get("choices") or [{}])[0].get("finish_reason") == "error"
                    and nonstream_body.get("hermes", {}).get("failed") is True,
                    "HTTP 200 is intentional soft failure: warning text plus finish_reason=error and hermes.failed=true", nonstream["name"])
        # Close our own response sockets only; never alter the server or host networking.
        for legacy_mode in [False, True]:
            prefix = "legacy" if legacy_mode else "native"
            for cut in ["byte", "frame"]:
                suffix = prefix + "-abort-" + cut
                target = self.name(suffix) if legacy_mode else self.create(suffix)
                trace = self.chat(suffix, legacy=legacy_mode, cut=cut, sid=target)
                self.result(suffix, trace.get("status") == 200 and bool(trace.get("body")),
                            "Client closed real response after " + cut + "; remote cancellation race requires status verification", trace["name"])
                self.check_http(suffix + "-reconnect", "/v1/models", 200)
                if not legacy_mode and cut == "frame":
                    fs = frames(trace.get("body", "").encode())
                    if fs and fs[0]["data"]:
                        rid = json.loads(fs[0]["data"]).get("run_id")
                        if rid:
                            self.check_http(suffix + "-status", "/v1/runs/" + rid, 200)
        self.check_stream("native-reconnect-chat", self.chat("native-reconnect-chat", sid=sid))
        self.check_stream("legacy-reconnect-chat", self.chat("legacy-reconnect-chat", legacy=True), legacy=True)
        timeout_sid = self.create("stream-read-deadline")
        timed = self.chat("stream-read-deadline", sid=timeout_sid, cut="idle-deadline")
        if timed.get("read_deadline_fired"):
            self.result("stream-read-deadline", True, "Real native SSE response read timed out at 1ms after first complete frame; socket closed. This is a Python client deadline, not Swift's 90s idle limit.", timed["name"])
        else:
            self.blocked("stream-read-deadline", "Server completed before the tiny client deadline; no timeout was observed.")
        self.check_http("stream-deadline-reconnect", "/v1/models", 200)
        # Different owned sessions, bounded four-way concurrency, genuine server replies.
        concurrent = [self.create("concurrent-" + str(i)) for i in range(4)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            traces = list(pool.map(lambda pair: self.chat("concurrent-" + str(pair[0]), sid=pair[1]), enumerate(concurrent)))
        for i, trace in enumerate(traces):
            self.check_stream("concurrent-" + str(i), trace)
        shared = self.create("shared-concurrent")
        with ThreadPoolExecutor(max_workers=2) as pool:
            traces = list(pool.map(lambda i: self.chat("shared-concurrent-" + str(i), sid=shared), range(2)))
        for i, trace in enumerate(traces):
            self.result("shared-concurrent-" + str(i) + "-http", trace.get("status") in {200, 409, 429},
                        "Same-session parallel requests return a stream or explicit admission rejection", trace["name"])
            if trace.get("status") == 200:
                self.check_stream("shared-concurrent-" + str(i), trace)
        # HTTP errors on a streaming request have real nested JSON diagnostics.
        # HermesBackend.sseStream calls validate(response) without passing the body.
        error_trace = self.request("QA-stream-http-error-detail", "/v1/chat/completions", method="POST", body={},
                                   headers={"Accept": "text/event-stream"})
        error_text = json.loads(error_trace.get("body", "{}" )).get("error", {}).get("message")
        self.result("stream-http-error-detail", not error_text,
                    "Source review: validate(response) discards real error.message on SSE open; server message=" + str(error_text), error_trace["name"])
        # A real partial upload gives deterministic client-side read timeout without
        # inventing a slow Hermes response or changing server configuration.
        conn = http.client.HTTPConnection(self.host, self.port, timeout=0.2)
        try:
            conn.putrequest("POST", "/v1/chat/completions")
            conn.putheader("Authorization", "Bearer " + self.key)
            conn.putheader("Content-Type", "application/json")
            conn.putheader("Content-Length", "1000")
            conn.endheaders(b'{"QA-upload":')
            try:
                conn.getresponse()
                self.result("partial-upload-client-timeout", False, "Server unexpectedly answered an incomplete upload")
            except socket.timeout:
                self.result("partial-upload-client-timeout", True, "Real incomplete HTTP upload; client timed out at 0.2s and closed socket. Does not test Swift stream idle/open deadlines.")
        finally:
            conn.close()
        self.check_http("after-timeout-reconnect", "/v1/models", 200)
        for name, reason in [
            ("provider-token-stream", "No provider key: successful tokens, tool lifecycle, long generation and provider fault timing unavailable."),
            ("server-idle-timeout-keepalive", "Missing provider finishes immediately; cannot exercise real 30s keepalives or Swift 90s idle timeout."),
            ("swift-runtime", "Linux box has no Swift toolchain/macOS UI. Compatibility conclusions use raw live traces plus source review."),
            ("app-qa-catalog", "Native DEBUG app and attested QA gateway absent. This direct transport pass does not run/claim the 65 app scenarios."),
            ("provider-429-502-503", "No provider credentials/fault control. Genuine 500 observed; no 429/502/503 observed or fabricated."),
            ("mid-token-abort", "First-byte/frame aborts exercised; an abort during meaningful generated content needs provider output."),
            ("swift-captured-truncation", "No Swift execution. Captured prefix has no terminal and source would throw StreamBreak; runtime verification deferred.")]:
            self.blocked(name, reason)

    def cleanup(self):
        self.cleaning = True
        # Wait for the owned native runs to reach a remote terminal state before
        # deleting session rows. Client disconnect is not proof of cancellation.
        run_ids = set()
        for trace in list(self.traces):
            if trace["path"].startswith("/api/sessions/") and trace["path"].endswith("/chat/stream"):
                for frame in frames(trace.get("body", "").encode()):
                    if frame["data"]:
                        run_id = json.loads(frame["data"]).get("run_id")
                        if run_id:
                            run_ids.add(run_id)
        for run_id in sorted(run_ids):
            status = None
            for _ in range(12):
                trace = self.request("QA-cleanup-run-" + run_id, "/v1/runs/" + run_id)
                status = json.loads(trace.get("body", "{}")).get("status")
                if status in {"failed", "completed", "cancelled"}:
                    break
                time.sleep(0.1)
            self.result("cleanup-run-" + run_id, status in {"failed", "completed", "cancelled"},
                        "Remote run terminal status=" + str(status), trace["name"])
        # Only exact IDs registered by this run; never list/delete by prefix.
        for sid in sorted(self.owned):
            trace = self.request("QA-cleanup-" + sid, "/api/sessions/" + sid, method="DELETE")
            self.result("cleanup-" + sid, trace.get("status") in {200, 404}, "Owned QA session deletion or already absent", trace["name"])
            verify = self.request("QA-cleanup-verify-" + sid, "/api/sessions/" + sid)
            self.result("cleanup-verify-" + sid, verify.get("status") == 404, "Exact owned session no longer readable", verify["name"])
        for _ in range(20):
            trace = self.request("QA-final-health", "/health/detailed")
            obj = json.loads(trace.get("body", "{}"))
            if obj.get("active_agents") == 0 and obj.get("api_server", {}).get("active_runs") == 0:
                break
            time.sleep(0.1)
        self.result("final-quiescence", obj.get("active_agents") == 0 and obj.get("api_server", {}).get("active_runs") == 0,
                    "Remote health: active_agents=" + str(obj.get("active_agents")) + ", active_runs=" + str(obj.get("api_server", {}).get("active_runs")), trace["name"])

    def save(self):
        report = {"run": self.run, "time": datetime.now(timezone.utc).isoformat(),
                  "endpoint": f"http://{self.host}:{self.port}", "model": self.model,
                  "scope": "direct real Hermes transport; app behavior is source review only", "results": self.results, "traces": self.traces}
        (self.output / "results.json").write_text(self.clean(json.dumps(report, indent=2)) + "\n")
        lines = ["# QA live transport results", "", self.run, "", "App/Swift projections are source-derived, not runtime execution.", "", "| Scenario | Status | Detail |", "| --- | --- | --- |"]
        lines.extend(f"| {r['name']} | {r['status']} | {r['detail']} |" for r in self.results)
        (self.output / "RESULTS.md").write_text(self.clean("\n".join(lines)) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    suite = Suite(args.output)
    try:
        suite.execute()
    except Exception as exc:
        suite.result("suite-execution", False, "Stopped with " + type(exc).__name__)
        raise
    finally:
        try:
            suite.cleanup()
        finally:
            suite.save()
    counts = {status: sum(r["status"] == status for r in suite.results) for status in ["PASS", "FAIL", "BLOCKED"]}
    print(suite.run, json.dumps(counts), str(args.output))
    return 1 if counts["FAIL"] else 2 if counts["BLOCKED"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
