# Debug QA hook proposal — design only, not implemented or enabled

## Why a hook is needed

The unmodified app has no test-mode gate or exhaustive app+Hermes sandbox attestation. macOS Accessibility/AppleScript can click visible controls, but cannot establish that a server-side terminal, browser, messaging skill or Composio route cannot send real traffic. Therefore a blind UI driver would violate the brief. The client in `run.py` refuses that state. This proposal adds a debug-only controller for the **real** AppStore and views, using the **real** Hermes backend; it does not replace Hermes replies with fixtures.

No source changes, entitlement changes, launch flags or listeners are included in this delivery. Implementing this proposal is separate work. Existing Swift tests/fixtures are not evidence that this hook exists.

## Build and activation boundary

Compile the controller, route definitions, test-mode state and sandbox dependencies only under `#if DEBUG`. Release builds must have no listener, routes or activation mechanism; verify this from a packaged release. Default is off even in debug. Explicit local launch in QA mode creates an isolated AppStore/data directory, QA-only keychain namespace, QA profiles and empty workspace; never migrate the production store or read production keys. No harness action may enable the mode or loosen its policy. A token does not grant general app control.

Use a random OS-assigned loopback port or configured unprivileged port, bind **only numeric 127.0.0.1**, and disclose it locally to the user. Generate a 256-bit random session token into an owner-only file; rotate on launch and invalidate on exit. Validate constant-time bearer token, exact Host, JSON content type, body size, method and route; reject browser Origin requests, CORS, redirects and URL-based tokens. Rate-limit bad auth and actions. No shell, arbitrary text, script evaluation, arbitrary selector clicking or unscoped file API. Avoid logging auth headers and untrusted error bodies. The current client pins numeric IPv4 and does not follow redirects or honor HTTP proxies.

MainActor handlers dispatch through the same send, fork, goal, loop, routine, approval and group/team methods used by the UI. The UI should visibly render those state changes. A separate Accessibility capture reads actual label/focus/window state and screenshots; internal state is not a visual or VoiceOver pass. Native UI scenarios remain blocked until such capture is implemented. Observe raw backend receipts rather than trusting assistant text.

## Visible and machine-readable QA identity

Show a persistent conspicuous **QA TEST MODE** window banner and `[QA-TEST]` badge on every QA chat/thread/group, routine, message, draft, approval, peer envelope, tool result and notification. Names start `QA-`; bodies carry the marker. Carry structured `test_mode=true`, run/scenario IDs and scope IDs through app persistence, Hermes session metadata, goal continuations, helper/review tasks, cron prompts/delivery and direct peer wakes. Replies produced by Hermes may lack a text marker; the app must visibly badge them from immutable session metadata. Other bots must reject an unmarked handoff into a QA scope and refuse QA messages destined for a real profile. Include `simulated` on tool results and distinguish a fake attempt from real delivery.

The badge is an identity aid, not the isolation mechanism. Metadata and routing must persist across restoration; a lost tag/metadata or unsupported Hermes propagation capability blocks execution. Do not silently rewrite the app's reserved heartbeat job name; keep A05 blocked until a separately specified QA namespace can exercise the actual implementation safely.

## Sandbox and watchdog prerequisites

The app's connected-app broker must inject recording-only tools instead of the production Composio client, provisioning, OAuth, feedback, web desktop and voice transports. Hermes must attest the matching policy on its **real QA profiles**: every tool, terminal/browser/CLI path, messaging skill, app connector, delegated agent and background job is either a known record-only stub or denied. No real connected accounts or credentials are present in that QA environment. The inventory must be exhaustive, including disabled but accessible connector bindings. QA server tool processes have deny-all egress; model transport runs through a separate explicit allowlist. No shell network escape or real-provider fallback.

Use `RecordingSandbox`'s payload/receipt contract for email, Slack, WhatsApp and generic connected-app tools. It has no network calls and records each attempt with payload hash, exact synthetic account/recipient/body, idempotency key and duplicate flag. The future broker can invoke it through local IPC; none is deployed now. Other harmless tools such as `qa_wait` and `qa_approval` need narrowly implemented sandbox adapters; their execution and decisions must produce receipts. Do not simulate real job success or server fault responses with these tools.

Before enabling any routine, register a server-side expiry and cleanup lease. The watchdog enforces three actual turns/120 seconds per scenario and 24 actual turns/900 seconds per run, including goal continuations, helpers, reviewers, peer wakes and cron. It blocks new work at the limit, stops only scoped in-flight QA work where supported, expires schedules independently of Mac/runner survival, and retains truthful unknown states for unconfirmed stops. If real Hermes cannot provide this isolation/watchdog, all live scenarios remain blocked. A local `finally` block alone cannot guarantee cleanup after client death.

## Protocol version `swarmhub-qa/1`

All routes are authenticated `POST /qa/v1/<route>`; maximum request/response 2 MiB, control timeout eight seconds. No long-running synchronous wait: acknowledge a checkpoint, then use read-only observation. Unsupported capabilities produce a blocked result before mutation. Request IDs, immutable intent IDs and scope IDs are independent. Persist action acceptance **before** execution, and reconcile repeat action IDs rather than re-executing; the client itself never resends an uncertain mutation.

| Route | Request | Response/obligation |
| --- | --- | --- |
| `attest` | Schema + fresh random nonce | Echo nonce, safety fields below, actual app build/commit/Hermes version, sandbox digest, capabilities and short-lived safety lease. Read-only. |
| `begin` | Exact `QA-<run>-<scenario> [QA-TEST]` resource; run/scenario IDs; marker; hard scenario/run budgets; current lease | Create/find only that QA scope and return `{acknowledged:true, resource:...}`. Reject pre-existing resources not owned by this lease/run, even if their names match. |
| `action` | Scope, unique action ID, one compiled `{op,prompt?,value?}` step, optional corresponding canned marked text, current lease | Atomically verify lease, scope and policy; execute app action; return matching action ID + acknowledged flag. No arbitrary text accepted even with a valid token. |
| `observe` | Scope and lease | Complete raw ordered event trace + native snapshot + evidence metadata; `capture_complete:false` until that bounded variant's observation window closes. Never return a verdict as a substitute for observations. |
| `cleanup` | Scope and lease | Restore scoped transport controls; clear QA goal/loop, cancel/stop QA teams/turns, pause/delete only owned routines and resolve/cancel only scoped waiters; verify remotely. Return integer `active_qa_work:0` and `remote_verified:true` only with server evidence. |

`attest` requires exact typed values: `debug_build`, `test_mode`, `real_app`, `real_hermes`, `isolated_qa_store`, `inventory_complete`, `sandbox_enforced_app`, `sandbox_enforced_hermes`, `default_deny_tools`, `egress_denied_except_model`, `qa_peers_only`, `qa_marker_propagated`, `watchdog_active` all true; integer `real_connector_count:0`; `production_jobs_accessible:false`; matching `nonce` and `schema`; nonempty `build`, `commit`, `hermes_version`, `sandbox_policy_digest`, `lease`; numeric `expires_at` within 60 seconds. `connectors` is a nonempty exhaustive list with `implementation:"record-only"`, `has_credentials:false`, `network_enabled:false` on every entry. `capabilities` lists supported operation/checkpoint names from the catalog. Missing/unknown safety state refuses execution.

Every action/observation/cleanup obtains a fresh lease. App and Hermes must recheck inventory revision, run ownership and watchdog **atomically at action execution**, not just at attestation. If a real connector appears between the two, reject without acting, invalidate the lease and let the already-isolated watchdog terminate QA work. The runner stops all remaining scenarios if scope cleanup cannot be confirmed.

## Checkpoints and deterministic fault boundaries

The hook should expose primitive operations, not a `runScenario` endpoint returning pass/fail. The runner controls the sequence and evaluates observations. Implement the catalog's explicit checkpoint capabilities: e.g. approval request has reached a known noop waiter before decision; a loop is paused while its first/only run is in flight; the first routine Run now is still busy when the second click occurs; a QA transport fault happens after real Hermes acceptance. `goal.subgoal` uses fixed “Include expected results”; draft main/thread text is synthetic and distinct; `draft.create` waits for A/B, discusses B, then permits `draft.send` A. `team.start` uses only preconfigured QA members, and group/plan/evidence variants require the listed capability. No primitive may secretly perform extra unreported actions.

Record checkpoints as events. Each action response means the named checkpoint was acknowledged, not that a task is correct or a message was delivered. If a real model fails to generate the required cards or tool request, record missing preconditions/blocked; never fabricate cards/approvals or inject a fake Hermes reply to force timing. Response loss can be tested by cutting only the real request's local stream/observer. 409/429/500, server restarts, historical clock/DST, missing capability servers and host loss need actual supported scoped controls or remain blocked. This delivery includes no such fault provider.

## Evidence and oracles

Observations include schema, run/scenario/resource, `capture_complete`, ordered unique integer `seq` events (each scope-bound with source `app`, `hermes`, `sandbox` or `accessibility`), explicit `observed_event_types`, state snapshot, screenshots, session/profile, usage before/after and available run/task/job/approval IDs. Timestamps and exact marked prompts/action IDs connect app UI with authoritative Hermes history/tool receipts. A missing event type cannot prove a zero count. State projections must be derived from captured data, never a model's assertion of success. Examples: `routine_paused_remote` is a fresh real jobs-list value; `drafts_independent` compares actual main/thread draft snapshots; `review_has_check_evidence` links the check receipt, not a “looks good” phrase.

The runner asserts exact counts, typed state equality and ordering. A02 allows zero continuation events only if continuation dispatch is explicitly instrumented; if any occur, history completion must precede all. Missing evidence is blocked. A failed oracle is a candidate bug for the bounded variant, with evidence retained, not automatic proof of full scenario failure. Cross-model verification requires actual runtime model identity; config labels are insufficient. No native UI/AX pass comes from internal state alone.

## Risks and acceptance before implementation

- Loopback exposes a local control interface to other processes and browser attacks; token protection, Host/Origin checks and narrow capabilities reduce that access. A compromised same-user process remains outside this trust boundary.
- Release inclusion or a listener bound to all interfaces could expose app data/control. Verify release absence and actual bound sockets independently.
- Prompt tags do not stop real outbound calls. Incomplete Hermes tool inventory, terminal escape, alternate credentials, delegation or a provider fallback defeats sandboxing; keep the gate closed without enforcement on both sides.
- QA name collision, prefix-only deletion or stale identities can touch real work. Require immutable scope ownership and isolated stores, not naming alone.
- Lost acknowledgement and runner/app death can duplicate work or leak schedules. Journal action IDs and independent server expiry are prerequisites; never infer completion from reclaimed slots.
- Screenshots/logs may capture real data if isolation fails. Capture only QA windows, redact secrets before export and retain evidence locally with user-only permissions.
- A hook can bypass native focus/validation or alter timing. Use the same app methods plus separate AX observations; reserve full native accessibility acceptance for real UI tests.
- Real LLM inference still costs tokens and can be nondeterministic. Hard budgets bound work but are not exact billing limits. Model refusal or unavailable tool support is blocked, not a passing substitute.

Before permitting live use, test auth/release/binding/scope rejection, attempt bypass through each app and Hermes tool path, kill the local runner while a QA schedule exists and verify remote expiry, verify tag persistence, and check no real connector can load mid-run. These are implementation acceptance requirements, not checks performed here.
