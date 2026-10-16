# Isolated DEBUG QA mode

The app controller is implemented under `Sources/AgentApp/QA/`, behind `#if DEBUG`, and is off by default. **Live operation is still blocked without a real Hermes QA gateway that enforces the contract below.** This repository does not contain Hermes's server or agent runtime, so it cannot install its tool/process sandbox or watchdog. An ordinary Hermes endpoint is deliberately insufficient. No fake Hermes backend is supplied.

## Local launch on a Mac

Configure a dedicated, sandboxed real Hermes QA gateway on an unprivileged numeric IPv4 loopback port. The gateway key must be QA-only, 43–128 base64url characters. It must not be a production profile or model-provider key. Set these in the launch environment without printing the key:

```sh
export SWARMHUB_QA_HERMES_URL=http://127.0.0.1:49372
# Set SWARMHUB_QA_HERMES_TOKEN through your local secret mechanism.
./scripts/run-qa.sh
```

The script forces a debug build and records source provenance using read-only Git commands. Both SwiftPM and the swiftc fallback define DEBUG for debug builds. It never launches a remote Mac. The app prints an `endpoint.json` path and shows a conspicuous `[QA-TEST] QA TEST MODE` window. Each launch creates a fresh mode-0700 `swarmhub-qa-*` directory under the OS temporary directory, with its own store, defaults, SQLite ledger, caches, screenshots, recorder and journals. It never imports the real app store or credentials. Tokens/descriptors/journals/checkpoints/screenshots/sink files use mode 0600. Evidence directories are retained and should be copied before OS temporary cleanup.

Then run in a second local terminal, using the printed path:

```sh
python3 -B sim/run.py --mode live --scenario F03 \
  --endpoint-file /private/var/folders/REPLACE/swarmhub-qa-REPLACE/endpoint.json \
  --output sim/results/mac-qa-first-chat
```

`--endpoint-file` checks ownership, permissions, protocol, port and token-directory ownership. Alternatively the existing `--port` and `--token-file` arguments work. The app chooses a random port and rotates its token on each launch. Offline mode remains the default. Linux live mode refuses before contacting the endpoint. No action asks for human confirmation inside the allowlist.

A missing/invalid launch configuration exits 78 before ordinary app startup. A gateway that is absent, unmodified, or cannot prove isolation blocks attestation before any chat/session creation. Never replace the gateway with a forwarding-only proxy or manually assert safety flags to bypass this gate.

## App endpoint

Only numeric `127.0.0.1` is bound. All calls are `POST /qa/v1/<route>` with exact `Host: 127.0.0.1:<port>`, `Content-Type: application/json` and `Authorization: Bearer <file token>`. There is no CORS, browser Origin, GET, URL token, chunking, duplicate header or pipelining support. Headers are capped at 16 KiB and JSON at 2 MiB. Connections expire after eight seconds; at most eight connections and 600 requests/minute are admitted (including failed auth). The token is never logged.

`attest`, `begin`, `action`, `observe`, `cleanup` retain the harness's `swarmhub-qa/1` request shape. `attest` is read-only. All other calls need a fresh one-use local safety lease, exact schema/run/scenario/resource, and immutable run ownership. Only catalog scenario IDs are accepted. Names must exactly equal `QA-<run>-<scenario> [QA-TEST]`; prefix matching never authorizes access. Concurrent handlers in one scope are refused. Acceptance is journaled and fsynced before execution; a repeated acknowledged action ID is reconciled, while an uncertain ID is blocked and never executed again. A different payload under the same ID is refused/blocked.

The implemented action subset is:

- `chat.send`: `marker`, `list`, or `wait` prompt selector; exact compiled text only.
- `chat.stop`: the owned QA bot conversation only.
- `approval.request`: the compiled `approval` prompt. `approval.decide`: `approve` or `deny`, exactly one pending `qa_approval` with command `qa_approval [QA-TEST]` in the owned session. A denial permanently prevents approving that fixed intent under a new request ID in the same scope.
- `routine.create`: compiled `marker` prompt, exact QA name, `1m`, initially paused by the gateway before it can fire. `routine.run/pause/delete`: only the one job recorded as owned by this scope. They use the existing AppStore routine methods.
- `checkpoint` and `restart.prepare`: closed preparation hooks. They are also direct routes with the common scoped fields. Checkpoints save an immutable snapshot of the owned QA bot and journal receipt. Restart preparation first requires remotely verified zero active work, then revokes transport and writes the checkpoint. Neither hook kills/relaunches processes, imports arbitrary files, resumes sessions, or replays work after launch. Cold restart/recovery remains unsupported and is not advertised as such.

The app intersects its implemented capabilities with the gateway inventory. Goals, loops, threads, groups, teams, history/fault controls, arbitrary text, account/model edits and native Accessibility are not advertised. Catalog scenarios requiring them remain blocked before `begin`. The reserved heartbeat remains blocked.

`observe` combines the gateway's raw scoped trace/usage with actual AppStore messages and a PNG of the QA window's content view. Answer marker/origin and stream-preservation projections come from app state and received deltas. Missing app delta capture omits its oracle. This is a content-view capture, not an Accessibility/focus or screen-compositor test. The QA workspace renders real AppStore messages with the existing MessageView; it restricts editing surfaces. It does not certify the normal workspace's toolbar/composer/navigation behavior.

The `record` route adds `marker`, `tool`, `payload`, `attempt_id` to the common fields. It accepts only the same tools and synthetic payloads as `sim.run.RecordingSandbox`: `email.send`, `slack.send`, `whatsapp.send`, `connected.read`, `qa_wait`, `qa_approval`; account `QA-sandbox`; marker `[QA-TEST]`; recipients absent/null, `a@example.invalid`, `b@example.invalid`, or `QA-sink`; bodies absent/null, `[QA-TEST] A`, or `[QA-TEST] B`. Unknown parameters/tools/real values are refused with a payload-free refusal log. SHA-256 matches Python's canonical contract. Every attempt, including duplicates across recorder reopen, is retained. Changed data under the same attempt ID is refused. Receipts always have `simulated:true`, `delivered:false`; they never constitute successful real delivery. A recorder I/O error must fail the tool, never fall back to a provider.

## Required real Hermes gateway contract

This is the integration boundary, **not a shipped or tested server implementation**. The gateway must live on the same Mac/loopback boundary or be securely provisioned there independently; the app has no remote-host option.

`POST /qa/hermes/v1/control` receives authenticated JSON with `route`, `test_mode:true`, and the original scoped request fields. The app's first `attest` also supplies a private `recorder` registration containing local host, port, token and route. This registration must remain in memory, never in model context, tool results or logs. The gateway needs an independent controller to obtain fresh app `attest` leases before `record` callbacks; it must handle this asynchronously to avoid deadlock with a streaming model turn.

Control operations:

| Route | Obligation |
| --- | --- |
| `attest` | Echo the fresh nonce and full typed safety proof in DEBUG-HOOK-DESIGN.md. Inventory must include distinct `name` entries for email, slack, whatsapp, connected-apps, terminal, browser, http, coding, peers and background, plus every other binding. Each is record-only, credential-free and network-disabled. Return an unguessable never-reused lease valid at most 60 seconds, version/policy digest and honest capabilities. |
| `begin` | Persist exact `scope_id`/run/resource ownership and a server-expiring lease **before** acknowledging. Enforce 3 actual turns/120 seconds per scope, 24 actual turns/900 seconds per run, and 120 requested actions. Provision an empty dedicated QA profile/workspace/memory with no production sessions/accounts/credentials. Echo `scope_id` and `acknowledged:true`; this does not replace native session creation. |
| `authorize` | Read-only validation/reservation for the action or observation; validate the compiled action policy independently. Echo scope ID/acknowledgement. Native requests must recheck the same policy atomically; this is never permission to forward arbitrary API calls. |
| `observe` | Raw, ordered, uniquely sequenced scope-bound Hermes/sandbox receipts, instrumented event types, actual session/profile/usage and truthful capture-completion state. Never synthesize app behavior or verdicts from model prose. |
| `cleanup`, `restart.prepare` | Stop scoped work, cancel waiters, expire/pause/delete owned schedules and verify remotely. Only return integer `active_qa_work:0` and `remote_verified:true` after authoritative checks. Cleanup must also handle a begin whose response/session creation was lost. |

Real native Hermes calls go under `/qa/hermes/v1/native/<scope_id>/<native path>`. The app continues to use its existing HermesBackend, native session APIs, SSE parser, job client and approval path. It forwards no production API key. Headers carry `X-QA-Test-Mode:true`, marker, scope, run, scenario, resource, accepted action ID and the current safety lease. The gateway must atomically enforce inventory revision, expiry, ownership, exact allowed native method/body/session/job/run IDs and idempotency on **each** request; matching headers or a previous `authorize` response are insufficient. No legacy chat, profile enumeration, global job/session listing, model edits, production history or real-account reads may escape the scoped adapter. Read responses must include only the owned namespace.

Session creation must retain the exact requested QA ID/title and immutable QA metadata. Every continuation/reply/routine/tool result and peer envelope must retain it. Routine creation must be **atomically paused** with server-side maximum-one-run/expiry policy; the app's later pause cannot close a create-then-pause race. Repeated native submissions must reconcile rather than rerun. All tool, connected-app, email/Slack/WhatsApp, terminal/browser/CLI, raw HTTP, skill, delegated-agent, peer and background paths must either invoke the recording sink or deny and record refusal. No real implementation or credentials may be reachable, including disabled bindings. Tool processes need OS-enforced deny-all egress and a dedicated empty filesystem/credential environment; only separately isolated model transport may access explicit model-provider destinations. The independent watchdog must keep enforcing budgets and schedule expiry if app/runner dies. A prompt, tool-name filter, attestation JSON, or an app URLProtocol cannot provide these server guarantees.

The app denies production Composio calls and all unapproved HTTP, including alternate loopback services, by default. Redirects/proxies/cache/cookies are disabled for QA transport. Keychain/browser/external app and voice process entrypoints refuse QA access. Updater, launch discovery, normal workspace commands/settings and post-turn management/report/review/automation side effects are absent from the QA path. This is application enforcement, not a claimed OS sandbox for the entire GUI process. Malicious same-user processes are outside the local token boundary.

## Validation still required on a Mac

Run `swift test --filter qa` (Swift Testing names begin with `qa`), the existing Swift suite, DEBUG launch and negative auth/scope tests; inspect actual listening sockets. Build release and verify QA symbols/routes/activation strings are absent from the executable, including the fallback release path. Exercise a real isolated Hermes gateway, tool bypass attempts, inventory drift, duplicate/ambiguous submissions, recorder failure, and watchdog cleanup after killing the runner/app. Verify normal app data/defaults/keychain unchanged. No Swift, native UI, release-binary, real Hermes, watchdog, or cold-restart acceptance was run on the Linux implementation host.
