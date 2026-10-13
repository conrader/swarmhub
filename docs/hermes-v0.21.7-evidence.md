# Hermes Agent v0.21.7 wire evidence

Verified 2026-10-13 against the official `v2026.9.24` source checkout (the release tag for Hermes Agent v0.21.7) at `/private/tmp/hermes-v0.21.7-src` and a throwaway gateway rooted at `/private/tmp/hermes-test/home`. No personal/fleet server was contacted. The checkout reports the date version because its editable package metadata is intentionally `0.0.0`; the release/tag mapping is recorded in the official v0.21.7 release.

## Source excerpts

Paths and line numbers below refer to tag `v2026.9.24`.

- `gateway/platforms/api_server.py:67-77` advertises `run_stop`, `run_approval_response`, `approval_events`, and `session_chat_streaming: True`; `:79-98` publishes the corresponding routes.
- `gateway/platforms/api_server.py:1121-1137` shows `_SessionEventQueue.payload()` stamping every session-stream payload with top-level `session_id`, `run_id`, sequence, and timestamp.
- `gateway/platforms/api_server.py:3121-3186` accepts client `id`/`session_id`, inserts it atomically, returns 409 `session_exists` on duplicates, and returns 201 with `{session:{...}}`.
- `gateway/platforms/api_server.py:3270-3303` caps each messages page at 500 and explicitly accepts `order` values `"oldest"` and `"latest"` (otherwise returning `"order must be one of: oldest, latest"`). The response reports `order or ("latest" if default_page else "oldest")`. AgentApp therefore requests `order=oldest` and pages until a short page, with a 100-page/50,000-row safety cap.

  ```python
  order = request.query.get("order")
  if order not in (None, "oldest", "latest"):
      return _error_response("order must be one of: oldest, latest", 400, code="invalid_pagination")
  # ...
  "order": order or ("latest" if default_page else "oldest"),
  ```
- `gateway/platforms/api_server.py:3615-3699` creates a run ID for session chat and emits `run.started`, `assistant.delta`, tool events, `assistant.commentary`, `assistant.completed`, and terminal `run.<status>` events. It passes that same ID as `active_run_id`.
- `gateway/platforms/api_server.py:4191-4205,4253-4254` registers the session-stream agent in `_active_run_agents[active_run_id]`.
- `gateway/platforms/api_server.py:3743-3752` binds session-stream approvals to the run ID and emits `approval.request`.

  The shared emitter at `gateway/platforms/api_server.py:113-126` copies the approval data into the event, redacts its top-level `command` in place, and then adds the run-event envelope. Thus `command`, `request_id`, and the envelope's `run_id` are all top-level fields:

  ```python
  event = dict(approval_data or {})
  if "command" in event:
      from gateway.run import _redact_approval_command
      event["command"] = _redact_approval_command(event.get("command"))
  event.update(_run_event(run_id, "approval.request", **fields, choices=_approval_event_choices(
      smart_denied=bool(event.get("smart_denied")),
      allow_session=event.get("allow_session") is not False,
      allow_permanent=event.get("allow_permanent") is not False)))
  ```
- `gateway/platforms/api_server_runs.py:1165-1216` accepts approval choices `once`, `session`, `always`, or `deny`, optionally scoped by `request_id`, and resolves that exact run approval. AgentApp sends `{choice:"once"|"deny", request_id}`.
- `gateway/platforms/api_server_runs.py:1253-1274` implements `POST /v1/runs/{run_id}/stop`, loads the active agent/task (including the active-agent fallback), interrupts it, and returns `{run_id,status:"stopping"}`. This reaches session-stream runs because of the registration above.
- `gateway/platforms/api_server.py:2153-2159` only normalizes the persisted session `source` label (`desktop` is allowed; unknown values become `api_server`). `:3140-3168` uses it when inserting the session row. Tool selection is independently fixed to the API-server platform at `:2942-2969`; the session source is not used to alter tools, prompt, approval policy, or execution behavior. AgentApp now uses the truthful `api_server` label.

## Captured throwaway-gateway transcript

The bearer value below is a throwaway local test value. Long capability output and routine security headers are shortened.

```text
> GET /v1/capabilities
> Authorization: Bearer agentapp-throwaway-evidence-key
< HTTP/1.1 200 OK
< {"features":{"run_stop":true,"run_approval_response":true,
   "approval_events":true,"session_chat_streaming":true,...},
   "endpoints":{"run_stop":{"method":"POST","path":"/v1/runs/{run_id}/stop"},
   "session_create":{"method":"POST","path":"/api/sessions"},...}}

> POST /api/sessions
> {"id":"agentapp_evidence_20261013","title":"AgentApp evidence",
   "system_prompt":"Evidence only","source":"api_server"}
< HTTP/1.1 201 Created
< {"object":"hermes.session","session":{"id":"agentapp_evidence_20261013",
   "source":"api_server","title":"AgentApp evidence",...}}

> POST /api/sessions  (same id a second time)
< HTTP/1.1 409 Conflict
< {"error":{"message":"Session already exists: agentapp_evidence_20261013",
   "code":"session_exists",...}}

> POST /api/sessions/agentapp_evidence_20261013/chat/stream
> {"input":"Reply with exactly evidence-ok","instructions":"Evidence only"}
< HTTP/1.1 200 OK
< event: run.started
< data: {...,"session_id":"agentapp_evidence_20261013",
   "run_id":"run_6694c268c66d4e4280344b0bd8a938d1","seq":1,...}
< event: message.started
< data: {...,"session_id":"agentapp_evidence_20261013",
   "run_id":"run_6694c268c66d4e4280344b0bd8a938d1","seq":2,...}
< event: assistant.completed
< data: {...,"content":"⚠️ Provider authentication failed: [local sandbox denial]",
   "session_id":"agentapp_evidence_20261013",
   "run_id":"run_6694c268c66d4e4280344b0bd8a938d1","seq":3,...}
< event: run.completed
< data: {...,"session_id":"agentapp_evidence_20261013",
   "run_id":"run_6694c268c66d4e4280344b0bd8a938d1","seq":4,...}
< event: done
```

This live capture proves authentication, capabilities, client session IDs, duplicate conflict behavior, session-stream routing, event names, and top-level IDs. It did not produce model tokens or a real approval pause because the throwaway process cannot read provider credentials. Approval and active session-run Stop are therefore source-verified plus fixture-tested, not exercised against a live provider-backed run.
