# LIVE QA pass 1 — QA Hermes loopback

Executed 2026-10-19 on this Linux box against `http://127.0.0.1:8742`, model
`hermes-qa-swarmhub`. Swarm Hub baseline: `2bc145c99581165846951d13b3d21b5105083c4b`.
The provisioned server README identifies Hermes source `eea83bb`, version 2026.9.24;
the live health API reports version `unknown`.

The final suite recorded **132 PASS, 17 FAIL, 7 BLOCKED checks** over 131 HTTP
requests. These are individual assertions, including cleanup and repeated
compatibility checks, not 156 independent product features. Failures group into
three confirmed bug classes below, plus an unresolved health/cleanup discrepancy.
The live suite exited 1, as expected for observed failures. The 46 Python harness
tests passed.

Evidence: [all checks](../../../sim/results/live-1/RESULTS.md),
[requests, headers and raw response bodies](../../../sim/results/live-1/results.json),
[later health observations](../../../sim/results/live-1/health-followup.json).
Run ID: `QA-LIVE1-20261019T083207-c7329d`; main suite 08:32:07–08:32:10 UTC
(10:32 Warsaw), follow-up through 08:33:00 UTC.

## Scope and method

Added [sim/live_transport.py](../../../sim/live_transport.py), a dependency-free direct
Hermes transport suite. The existing `sim/run.py --mode live` intentionally
requires the macOS DEBUG app and its attested gateway; those gates were preserved.
This suite is explicitly authorized by the throwaway-server brief and does not
claim to run the app, UI, sandbox gateway contract, or the 65 app scenarios.

The environment file was sourced without displaying its key. All suite names,
session IDs and titles start `QA-`; prompts are fixed and marked `[QA-TEST]`.
Only the specified numeric loopback endpoint was contacted. No proxy, redirect,
model-provider call, tool call, outbound connector, server configuration change,
process restart or commit was made. The server's existing todo/clarify restriction
was left intact. Response evidence excludes authorization headers and redacts the
loaded key if echoed. No production session was inspected or mutated.

Requests reproduce Swift's relevant wire shapes: bearer authorization,
`Content-Type: application/json`, multipart text content arrays, native
`input`/`instructions`, legacy `messages`/`model`/`stream`, and legacy
`X-Hermes-Session-Id`. Streams request `Accept: text/event-stream`,
`Accept-Encoding: identity`, and `Cache-Control: no-cache`.

**Swift was not executed:** no Swift toolchain/macOS runtime is installed here.
Compatibility verdicts combine real server traces with the checked-in Swift
source. The explicitly labelled Python projections illustrate the relevant
source branches; they are not independent execution evidence for the app.

## Scenario results

The evidence table lists every individual assertion. This table groups the
requested scenarios and their important variants; mixed outcomes are split.

| QA scenario | Verdict | Observed result / limit |
| --- | --- | --- |
| QA-connection | PASS | `/health` and authenticated `/health/detailed` return 200; detailed readiness is `degraded` specifically for the unconfigured model. Basic health is intentionally public. |
| QA-auth-missing-and-wrong | PASS | 401 without a key and with a wrong key on models, capabilities, session reads, legacy chat, session creation and native streaming. Mutation paths refuse before execution. |
| QA-auth-valid | PASS | Valid key yields 200 models/capabilities/session reads and streams, 201 on session creation. No key appeared in saved evidence. |
| QA-models | PASS | OpenAI-style `object:list`, `data:[{id:hermes-qa-swarmhub,…}]`; matches Swift's model parser. |
| QA-capability-selection | PASS | `features.session_chat_streaming:true`; Swift selects native sessions. Other object/string feature values do not prevent that boolean flag from being recognized. |
| QA-session-identity | PASS | Server preserves exact QA ID/title; a repeated ID yields structured 409. |
| QA-request-headers-and-shapes | PASS | Both native Swift-shaped requests and legacy text-part arrays accepted. Legacy `hermes-agent`, which Swift hard-codes, is also accepted as an alias; returned chunk model is the configured QA model. |
| QA-native-SSE-framing | PASS | 200, `text/event-stream`, chunked transfer, blank-line-delimited named JSON frames, no-cache and `X-Accel-Buffering:no`. Ordered `run.started`, `message.started`, `assistant.completed`, `run.failed`, `done`. |
| QA-legacy-SSE-framing | PASS | Role chunk, fallback warning content chunk, `finish_reason:error` chunk, then `data: [DONE]`. JSON data is one line per frame, matching the current Swift line parser. |
| QA-stream-opening-and-bounds | PASS | Full-stream response headers arrived in 1.3–32.1 ms in this run. No hang or oversized response observed. This is transport timing, not model performance. |
| QA-native-provider-error-wire | PASS | `assistant.completed` carries `completed:false`; next event is `run.failed`. Run status endpoint independently reports `status:failed`. |
| QA-legacy-provider-error-wire | PASS | Error chunk includes `error.message/type` and `hermes.completed:false/failed:true/error_code:agent_error`. Usage is zero. |
| QA-Swift-terminal-failure | FAIL | Swift maps both native and legacy traces to completed at the AppStore boundary. QA-BUG-01; source-confirmed, no UI execution. Reproduced across normal, reconnect and concurrent streams. |
| QA-nonstream-provider-error | PASS | Actual response is **200**, `finish_reason:error`, `hermes.failed:true`, `X-Hermes-Completed:false`, and warning text. This is the server's intentional soft-failure shape, not a 502 bug. |
| QA-HTTP-4xx | PASS | Unknown route 404, wrong method 405, missing owned-style session 404, duplicate session 409, invalid JSON/missing content 400. Structured 400/401/404/409 errors use nested `error.message` where applicable; route/method errors may be plain text. |
| QA-native-malformed-requests | PASS | Invalid JSON, `{}`, empty messages, wrong message shape, array/null/string top-level body, and invalid native input rejected with 400. |
| QA-legacy-malformed-request-shapes | FAIL | Four variants produce real plain-text 500: `[]`, `null`, `"QA-invalid"`, and `{"messages":["QA-invalid"]}`. QA-BUG-02. Ordinary invalid JSON/missing messages still return 400. |
| QA-Swift-HTTP-stream-error-detail | FAIL | Real 400/401 JSON diagnostics are discarded when opening SSE because `validate(response)` is called without response data. QA-BUG-03. Status remains available. |
| QA-abort-first-byte | PASS | Closed our actual native and legacy response sockets after one byte; subsequent authenticated connection succeeds. A one-byte prefix is not enough to recover a run ID. |
| QA-abort-first-frame | PASS | Read actual native `run.started` or legacy role frame byte by byte, then closed. Reconnect succeeds. Native observed run IDs subsequently reach a failed terminal state. This does not establish cancellation during active model generation. |
| QA-stream-client-read-timeout | PASS | After native first frame, a real 1 ms Python socket read deadline fired; the socket closed and models reconnect returned 200. Distinct from Swift's own idle timer. |
| QA-partial-upload-client-timeout | PASS | Incomplete real HTTP upload stalls response; Python client times out at 0.2 s and closes. Server still serves the next authenticated request. No assertion about server-side upload expiry. |
| QA-reconnect-new-turn | PASS | A native continuation and fresh legacy chat after response aborts both produce complete error streams; no automatic replay of an uncertain request. |
| QA-concurrent-distinct-sessions | PASS | Four parallel native requests return independent run/session IDs and well-formed error streams. Failure-state interpretation still fails QA-BUG-01. |
| QA-concurrent-same-session | PASS | Two simultaneous native requests on one QA session both return 200, distinct run IDs and complete error streams. Successful concurrent transcript ordering remains untested without model output. |
| QA-history | PASS | Swift-shaped oldest-first paged message GET returns the expected `data`/`pagination` envelope. Failed setup left only `session_meta`; Swift filters it. Run status retains warning output. No successful transcript persistence claim. |
| QA-owned-session-cleanup | PASS | All 15 exact registered IDs deleted or already absent, then individually verified with GET returning 404. No wildcard cleanup. |
| QA-observed-run-cleanup | PASS | All 10 native run IDs recovered from complete frames remotely report terminal `failed`. |
| QA-global-quiescence | FAIL | Final health repeatedly reports `api_server.active_runs:0` but `active_agents:1/gateway_busy:true`; persisted runtime timestamp advances. Still present about 50 seconds later. See unresolved observation below. |
| QA-successful-model-output-and-tools | BLOCKED | No provider key: no generated answer, todo/clarify lifecycle, approval, long turn, token throughput or real usage. |
| QA-Swift-idle-open-timeouts-and-keepalive | BLOCKED | The provider error finishes rapidly; no real long-idle stream/30 s keepalive. Swift's 20 s opening deadline, upload allowance and 90 s idle limit require runtime/fault testing. Python client deadlines above are narrower coverage. |
| QA-mid-token-cut-and-recovery | BLOCKED | No generated token stream. Prefix aborts do not prove preservation of partially generated text or remote cancellation during a model call. |
| QA-provider-429-502-503 | BLOCKED | No provider fault mechanism. Actual 500 exercised via malformed requests; no 429/502/503 observed or substituted. A model key alone does not guarantee these fault conditions. |
| QA-captured-EOF-Swift-runtime | BLOCKED | Prefix captures have no terminal event; source would throw `StreamBreak(delivered:true)`. No Swift runtime test, injected fake Hermes server, or claimed app recovery success. |
| QA-macOS-app-catalog | BLOCKED | Requires DEBUG app, macOS and separately enforced QA gateway/watchdog; a model key alone is insufficient. |

## Confirmed bugs and reproduction

### QA-BUG-01 — High — completion wins over explicit backend failure

**Native trace:** `QA-native-stream` contains `assistant.completed` with
`completed:false`, followed by `run.failed` and `done`. This is the path Swarm Hub
actually selects on this server. `parseNative` emits `.completed` for every
`assistant.completed`, ignoring its completion flags, then `.failed` for
`run.failed`. The latter has no string `error`/`message` here, so its diagnostic
becomes the generic `Hermes run failed.`

**Legacy trace:** `QA-legacy-stream` contains `finish_reason:"error"`, then
`[DONE]`. `parseLegacy` emits `.failed`, but `readEvents` unconditionally emits
`.completed` for `[DONE]`.

In both cases [AppStore+Turns.swift:79](../../../Sources/AgentApp/Stores/AppStore+Turns.swift#L79)
checks `completed` before `boxFailure`; the final result is `.completed` and
`TurnOutcome.classify` maps it to `.finished`. This also bypasses the intended
failure warning/reconciliation path. Relevant transport code:
[HermesBackend.swift](../../../Sources/AgentApp/Backends/HermesBackend.swift),
`readEvents` line 376, `parseLegacy` line 397, `parseNative` lines 406–409/441;
[TurnState.swift:42](../../../Sources/AgentApp/Models/TurnState.swift#L42).

Repro: create an exactly named `QA-…` session using Swift's create body, then
POST `{"input":[{"type":"text","text":"[QA-TEST] Reply QA-OK. Do not use tools."}],"instructions":"[QA-TEST] Do not use tools."}`
to `/api/sessions/<id>/chat/stream`. With this server's missing key, the recorded
five-event sequence is deterministic. Legacy repro: POST Swift-shaped
`model:"hermes-agent",stream:true,messages:[…]` with `X-Hermes-Session-Id:QA-…`.
Run the suite below for both exact request bodies and source projections.

Expected: explicit failure remains failed/incomplete after transport terminators;
`assistant.completed` with `completed:false` cannot independently certify success.
Fix direction: respect native result flags/run terminal status, prevent `[DONE]`
from overriding failure, and give failure priority in turn classification. No
production source was changed during this QA pass.

### QA-BUG-02 — Medium — malformed legacy JSON shapes cause HTTP 500

POST each of these authenticated bodies to `/v1/chat/completions`:

```json
[]
null
"QA-invalid"
{"messages":["QA-invalid"]}
```

Expected: 400 with a bounded validation error. Actual: 500,
`Content-Type:text/plain; charset=utf-8`, body
`500 Internal Server Error\n\nServer got itself in trouble`.
Evidence: `QA-legacy-malformed-array/null/scalar/invalid-message`.
The native endpoint rejects the same shapes with 400.

Local server source explains the result: `_handle_chat_completions` calls
`body.get` without an object check; `_parse_chat_messages` calls `msg.get`
without checking each element. The native `_read_json_body` already validates
top-level objects. This is a Hermes server bug; Swift normally sends valid shapes.

### QA-BUG-03 — Medium — streaming errors lose actionable diagnostics

POST `{}` to `/v1/chat/completions` with `Accept:text/event-stream` and valid
bearer auth. Actual 400 body:

```json
{"error":{"message":"Missing or invalid 'messages' field","type":"invalid_request_error"}}
```

A wrong-key streaming request returns 401 with nested message
`Invalid gateway API key (API_SERVER_KEY)` and code `gateway_auth_failed`.
Evidence: `QA-stream-http-error-detail`, `QA-auth-native-stream-wrong` and
`QA-auth-chat-wrong`.

Swift's `sseStream` calls `validate(response)` at line 339 before consuming any
error bytes. Its default `data:Data()` means the otherwise correct nested error
parser at lines 481–483 cannot see these bodies; the message becomes empty or
generic. Nonstream `jsonRequest` passes actual response data and preserves it.
Legacy in-stream errors also contain actionable `error.message`/`hermes.error`,
but `parseLegacy` discards these in favor of a fixed failure sentence.

Expected: preserve status and bounded, redacted server error text on HTTP stream
open and in-stream failure. This mismatch is source-confirmed against real
response bodies; rendering in the app remains untested.

## Unresolved cleanup observation — QA-health-busy-after-stream-timeout

The first two transport runs ended with health reporting zero active agents and
zero API runs. The final run added an actual native read timeout, and ended with
zero API runs but one active agent. The discrepancy persisted through four
read-only follow-ups at 08:32:57–08:33:00 UTC, including a newer persisted runtime
`updated_at`. All captured native run statuses are terminal, and every owned
session is absent.

This is a failed quiescence check, **not proof of a running leaked agent or proof
that the timeout caused it**. `/health/detailed` gets `active_agents` from persisted
gateway runtime state and API run counts from the live adapter. Stale accounting
and an actual untracked task both need investigation. Repro candidate: bounded
suite including `QA-stream-read-deadline`, followed by repeated authenticated
`GET /health/detailed`. No further turn-producing probes or server restart were
performed after this failure. Deleted session rows and terminal run statuses do
not justify reporting full remote quiescence as passed.

## Re-run and remaining work

```sh
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
python3 -B sim/live_transport.py --output sim/results/QA-live-repeat-unique
python3 -B -m unittest discover -s sim -p 'test_*.py' -v
```

Use a fresh directory; existing results are never overwritten. Inspect/resolve
the busy-health discrepancy before another turn-producing suite. The runner is
bounded to 24 possible turns, four-way concurrency, 160 main-suite requests and
180 seconds, with separate bounded cleanup. It never retries an uncertain chat
mutation. Every trace includes method/path, a request body, response status,
headers and bytes; auth is recorded only as `valid/missing/wrong`.

Earlier evidence is retained in `live-1-initial` and `live-1-final`. The exploratory
initial run incorrectly expected nonstream failure to be 502. Inspection of the
actual warning response and server's soft-failure branch corrected that assertion
to 200 plus explicit failure flags in subsequent runs. That initial assertion is
not a product bug. `live-1` is the authoritative expanded run for the totals above.

After the model key is supplied, repeat with expectations changed from missing-key
errors to successful completion. Cover generated deltas, unicode/content fidelity,
normal native/legacy terminal events, transcript persistence, todo/clarify events,
actual usage, mid-token cancellation and reconnect without duplicate turns. Use a
controlled slow turn for keepalives and idle deadlines; provider 429/5xx and
before-header outages additionally need a controlled fault mechanism. Run Swift
and native UI coverage on macOS with the required isolated QA gateway. A provider
key does not supply that app-side infrastructure.

Changed only the Python transport harness, its safety/framing tests, sim README,
and report/evidence files. Existing Python suite: **46/46 passed**. No Swift build
or test run claimed; no app/server fixes and no commit made.

## Fixes

App changes for QA-BUG-01 and QA-BUG-03 are now implemented in this worktree:

- **QA-BUG-01:** Native terminal results respect `completed:false`, failure,
  partial and interruption flags. The stream sink remembers failure diagnostics
  and suppresses subsequent success events; legacy `[DONE]` cannot override an
  earlier failure. The shared turn consumer gives explicit failure priority in
  either event order. The captured native `run.failed` has no error text, so it
  retains the preceding unsuccessful assistant result's warning instead of
  replacing it with `Hermes run failed.` Richer error payloads preserve their
  message and code; legacy `error.message` and `hermes.error/error_code` are read.
- **QA-BUG-03:** Non-success responses to SSE requests now read up to 64 KiB of
  response bytes with a separate control timeout before HTTP validation. JSON
  message/code and plain-text diagnostics reach the alert and persisted warning.
  Displayed diagnostics are redacted using the connection key and shared secret
  filters, then limited to 2,000 characters. Empty, oversized, interrupted or
  unclosed error bodies retain their HTTP status and a usable fallback.
- **QA-BUG-02:** No Hermes server changes were made. The app retains HTTP 500
  as an HTTP error, preserves its plain-text diagnostic, and keeps the existing
  ambiguous delivery classification rather than reporting a finished reply.

Implementation: [HermesBackend.swift](../../../Sources/AgentApp/Backends/HermesBackend.swift),
[HermesBackend+Errors.swift](../../../Sources/AgentApp/Backends/HermesBackend+Errors.swift),
and [AppStore+Turns.swift](../../../Sources/AgentApp/Stores/AppStore+Turns.swift).
Regression tests: [HermesLiveRegressionTests.swift](../../../Tests/AgentAppTests/HermesLiveRegressionTests.swift).
The Swift tests embed the exact captured native/legacy SSE bodies, 400/401 JSON
bodies and plain-text 500 body from this report's evidence. They exercise backend
parsing and AppStore reply state, alerts and warning rows. Additional cases cover
conflicting terminal order, detailed failure replacement, completion flags,
successful completion, redaction, oversized bodies and an unclosed error body.
All network requests in these tests use an in-process URLProtocol stub.

Validation on this Linux box: all five embedded response bodies were compared
byte-for-byte with `sim/results/live-1/results.json`; all embedded SSE JSON frames
parse successfully. `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`
passes **46/46 tests**. These Python checks do not execute the Swift changes.
**Swift compilation, Swift tests and app/UI execution remain unverified:** no
Swift toolchain/macOS runtime is installed here. Run the new Swift tests and the
existing stream/turn tests on macOS before treating the app fixes as runtime
verified. No live server requests, server modifications or commit were made by
this fix pass; existing QA harness and evidence files were preserved.
