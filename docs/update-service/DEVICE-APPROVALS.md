# Device approvals v2 (P5a)

Offline contract for CORE-PLAN.md §4. P5a adds no runtime path. The reference is
`scripts/approvals/device_approval_reference.py`; P5b supplies transactional box
storage/verification and P5c supplies the Mac client. Decisions go directly to the
destination box, independently of the update host. Hermes and native Hermes
approvals are unchanged.

## Message and signature

UTF-8 JSON, at most 16 KiB, exactly `{"signed":{...},"signature":"<128 lowercase hex>"}`.
`signed` has exactly these fields (all required, no extensions in v2):

| Field | Rule |
| --- | --- |
| `version`, `domain` | Integer `2`, literal `swarmhub/device-approval/2` |
| `key_id` | Enrolled device key ID, `[A-Za-z0-9._-]{1,64}`; signed, never selected from an unsigned header |
| `origin` | Exact operator-configured HTTPS origin; lowercase ASCII DNS/IPv4 authority, optional non-default port (1–65535, canonical decimal); no credentials, path, query, fragment or trailing slash. Default 443 omitted. No redirects or forwarded-header inference. IPv6 requires a later contract. |
| `runtime` | Persistent box runtime UUID, lowercase `8-4-4-4-12` hex; changes on replacement/reinitialization |
| `profile` | Current local policy's decider profile, `[A-Za-z0-9_-]{1,64}`; must equal the destination profile |
| `task` | Exact `task.` plus 32 lowercase hex |
| `fingerprint` | SHA-256 of **JCS(full frozen operation spec)**, 64 lowercase hex |
| `gate` | `owner` or `coordinator`, equal to the current operation gate |
| `approved` | Boolean: `true` approves, `false` denies; no other meaning |
| `nonce` | 32 box-generated cryptographically random bytes, encoded as 64 lowercase hex |
| `issued`, `expires` | Nonnegative safe integer Unix seconds from the box; `0 < expires-issued <= 60` |

Use the P0a [JCS profile](SCHEMAS.md#2-canonical-json-jcs-profile) unchanged:
ASCII unique member names, sorted keys, UTF-8, minimal escaping, array order
preserved, safe integers, no floats/exponents/negative zero/null/BOM/lone
surrogates, depth ≤32. Parse strictly, then canonicalize `signed`; outer JSON need
not be canonical. All patterns match the whole string. Booleans are not integers.

Sign exactly ASCII `swarmhub-device-approval/2` + LF + `JCS(signed)` with **pure
Ed25519 (RFC 8032), no prehash**. Public keys are 32 bytes (64 lowercase hex).
Require canonical point encodings, nonidentity prime-order public key and R,
`S < L`, and `[S]B = R + [H(R || A || message)]A`. Never reuse release, recovery,
Hermes, or OpenClaw keys or signature domains.

The fingerprint includes every spec field and value, including intent, arguments,
recipients, text, risk flags, fake mode and verification settings; never a display
summary or the reduced execution-only fingerprint. Recompute it from the box's
stored spec before deciding. v1 uses different JSON escaping: P5b must compute the
v2 JCS fingerprint separately, rather than assume the v1 digest is identical.

## Nonces and local authority

The box issues a nonce only for a pending operation and an active locally enrolled
device authorized for its current decider profile. It persists an immutable
binding of **all signed fields except `approved`**, including key ID and box-owned
times. The client returns those fields unchanged after reviewing the full spec.
Unknown nonces, changed bindings, future issue times and `now >= expires` reject;
there is no clock grace. Client-chosen/reconstructed nonces are never accepted.
Lost state fails closed. A replaced runtime invalidates outstanding challenges.

Under one transaction/lock, re-read enrollment/revocation, current policy, full
spec, pending gate and nonce; verify signature and scope, recheck box time after
waiting, then mark the nonce used, commit the decision and its bound receipt
atomically. Exactly one concurrent consume can succeed. A rejection consumes
nothing. A consumed nonce always rejects, including an identical retransmission.
Keep used records until expiry; expired records may be pruned, never reissued.
A missing record still rejects. No wake/execution happens before commit.

On an uncertain acknowledgement, query the committed receipt; never reapply the
decision. Receipt reads are idempotent and bind runtime/origin/profile/task/full
fingerprint/gate/decision plus device ID, nonce and signed-message digest. A query
or receipt cannot itself authorize work. Response authentication/transport and
receipt storage remain P5b/P5c work, preserving v1's no-redirect and receipt checks.

Each device/box pair has a new approval-specific private key held by the app's
Keychain (no Secure Enclave claim). Console/authenticated-SSH operator actions,
outside model turns, enroll a public key with explicit allowed decider profiles
or revoke it locally. Revocation is checked at consume time and invalidates all
outstanding challenges. IDs are never reused; rotation enrolls a new ID and
revokes the old one. No central roster, bundle, flag or update-service secret
can enroll a device, weaken gates or clear revocation.

## v1 coexistence and verdicts

Before explicit local cutover, Mac v1 Bearer/HMAC decisions keep their existing
verifier and fixture unchanged. A v2 failure never falls back to v1. The reference
returns `defer/legacy_v1` for v1 on a legacy box: **not approval**, dispatch only.
A device-required box rejects every v1-only decision with `device_required`,
even a correct HMAC. This persistent mode survives restarts and flag changes;
recovery requires an explicit local operator action. iOS offers managed approvals
only on device-required boxes and has no shared-key decision path.

Device-required mode also refuses unsigned local gateway decisions, including
`swarmctl decide` and the local client's `swarmctl control decide` path. These
paths check the device list and persistent mode under the decision transaction
lock; they cannot fall back to gateway identity, v1, or an environment flag.
Use a valid device signature through the v2 verifier to decide on such boxes.
Unenrolled and explicitly legacy boxes retain their existing local gateway and
v1 behavior, provided their local device state is valid.

First failure wins: trusted snapshot validity → strict JSON/envelope/field shape
(`schema_invalid`) → version/domain (`protocol_unsupported`) → local device
(`device_unknown`, `device_revoked`) → signature (`signature_invalid`) → exact
box/profile/device authorization/task/fingerprint/gate/pending state
(`box_mismatch`, `profile_mismatch`, `device_unauthorized`, `task_mismatch`,
`fingerprint_mismatch`, `gate_mismatch`, `operation_not_pending`) → nonce existence,
binding, unused status, mode validity and time (`nonce_unknown`, `nonce_mismatch`,
`nonce_replayed`, `mode_changed`, `nonce_not_yet_valid`, `nonce_expired`) → `accept/ok`.
Invalid local state returns `reject/state_invalid`; any unclassified malformed
input rejects. All checks precede consumption. v1 dispatch checks local mode
before any v1 authentication; it cannot grant device-required authority.

Run `PYTHONDONTWRITEBYTECODE=1 python3 scripts/approvals/device_approval_vectors.py --check`
and `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_device_approval_vectors.py -v`.
The fixture has 40 vectors: valid allow/deny and boundaries, every signed field
tampered, wrong box origin/runtime/profile/task/fingerprint/gate, nonce replay,
expiry/boundary/future/unknown/binding mismatch, revoked/unauthorized/unknown
devices, wrong key/domain/version, final/corrupt operation, and both v1 modes.
Seeds are public TEST-only material under `Tests/Fixtures/release-bundles/`,
separate from all release keys. Regeneration must be byte-identical.

## P5b box implementation

Box code is in `Resources/Skills/swarmhub-messages/scripts/`: `swarm_device_state.py` (shapes, Ed25519/JCS
checks, local state), `swarm_device_approvals.py` (challenge/decide/receipt), `swarm_devices.py` (operator CLI),
and `swarm_jcs.py`/`swarm_ed25519.py`, byte-identical copies of the updater's modules (a test enforces it).
`swarm_remote.py` keeps v1 and routes v2. Nothing on these paths opens a network connection or reads the
update host; the device list, mode and nonces are local tables in `~/.hermes/swarmhub/control.sqlite`.

**Endpoints** (POST, same loopback listener as v1, no shared key read): `/swarmhub/control/v2/<profile>/<verb>`.

| Verb | Body | Result |
| --- | --- | --- |
| `challenge` | signed read request | `{request, challenge, record, mode}`: a fresh nonce binding (all signed fields except `approved`) and the full stored operation |
| `decide` | the P5a envelope | `{request, receipt}` |
| `receipt` | signed read request | `{request, receipt, mode}` or `{request, receipt: null, status, observed_at, record, mode}`; exactly `{request, receipt: null, status: "gone"}` when gone; never authorizes |

`mode` (skill 1.4.3+) is `"required"` or `"legacy"`, read under the same lock as the rest of the response. It is
reporting only: the box's checks are unchanged, and the Mac ignores it.

`request` is SHA-256 of the raw body. Refusals are HTTP 403 `{"error":"control request refused","reason":<code>}`.
Responses are authenticated by TLS to the operator-configured origin (the client keeps v1's no-redirect rule);
the box holds no signing key.

Pending receipt reads include the full stored operation, current decider and `remoteBinding`
(origin/runtime/decider profile). The Mac uses these reads to display pending cards without creating
nonces. Only a decision asks for a fresh challenge, then checks it against the reviewed operation.
The Mac persists its exact signed attempt before dispatch. A recognized HTTP 403 box refusal clears
that attempt and the card's saved choice, allowing another explicit retry or deny. Timeouts, unknown
results, redirects, invalid receipts and server errors retain the attempt; only receipt reconciliation
may resolve them. A decision receipt is adopted. A saved attempt can be cleared only when its nonce
has expired at the fresh receipt read's `observed_at` box timestamp and the validated record still shows
pending with no decision. The box snapshots this integer Unix time and record under the same transaction
lock used for decisions; the Mac clock cannot establish expiry. Missing/invalid `observed_at` keeps a
saved attempt locked (including against older boxes until their skill is updated).
That reconciliation also clears the card's saved choice and stops, whichever read cleared the attempt
(a decision retry or a repeated approval notification); the user must review and may approve or deny.
Before expiry, or if the receipt read fails or is invalid, the attempt stays locked. Nothing
automatically resends a decision. Read refusals use the normal user-facing rejected error.
In the same transaction as that read, the box records every unused nonce of the task whose `expires` is at
or before `observed_at` in `approval_expired`. A decision for a recorded nonce is refused `nonce_expired`
even if the box clock later steps back below `expires`; the marks are pruned with their challenges.
A receipt read that answers exactly `{request, receipt: null, status: "gone"}` (no receipt and no stored
operation, so nothing can commit) clears the saved attempt and the card's choice and shows "The box no
longer has this operation, so no decision was recorded"; any other shape keeps the attempt.

The Mac fixture stores canonical payload/message bytes, public keys, and signatures. Ed25519 signatures
from CryptoKit may be randomized: both Swift and Python verify stored signatures instead of comparing
fresh signatures. On the Mac, run `SWARMHUB_WRITE_DEVICE_FIXTURE=1 swift test --filter DeviceApprovalIdentityTests`,
then plain `swift test`, then `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_mac_device_approvals.py -v`.
The Python check verifies the stored fixture through P5b without regenerating expected signatures.

A **read request** is `{"signed":{...},"signature":...}` signed over ASCII `swarmhub-device-request/2` + LF +
`JCS(signed)`, with exactly `version` 2, `domain` `swarmhub/device-request/2`, `verb` (`challenge`/`receipt`,
equal to the path), `key_id`, `origin`, `profile` (equal to the path), `task`, `issued` (client Unix seconds,
accepted within `[now-60, now+5]`). It must come from an active device enrolled for that profile. A challenge
also needs the profile to be the operation's current decider and the operation to be pending. Each device may
hold 8 unused live challenges (`challenge_limited`); the box refuses to issue while its clock is behind an
already issued challenge. New reason codes on reads only: `request_expired`, `challenge_limited`.

**Decide** runs the documented order in one `BEGIN IMMEDIATE` transaction, reads the box time after the lock,
then marks the nonce used, records the decision (`decide_in_transaction`) and the receipt, and commits; the
worker wakes after commit. A retransmission rejects (`operation_not_pending` once decided, else
`nonce_replayed`); clients query `receipt`. The receipt is the v1 record plus `remoteReceipt` with `protocol` 2,
`device`, `nonce`, the v2 `fingerprint` and `message` (SHA-256 of the signed message); its `remoteBinding` has
v1's shape, so a legacy v1 `get` reads the same receipt. A v1 body on a v2 path is refused (`legacy_v1` is
dispatch advice, never approval).

**Fail closed.** Every call re-validates every device, mode and challenge row and the runtime. A malformed
row, a mode row missing while devices exist, a non-finite or out-of-range clock, or a spec that fails its
stored digest is `state_invalid`. v1 checks the mode (and that the device list is valid) before any v1
authentication and again under its transaction lock, so a corrupt store or a cutover mid-request refuses v1.
Every stored public key must decode canonically to a nonidentity prime-order Ed25519 point, using the
same check as enrollment. An invalid key anywhere, including a revoked device, makes the whole list
corrupt and refuses v2, unsigned local decisions, and v1 even in legacy mode.

**Operator CLI** (`python3 swarm_devices.py list|enroll|revoke|mode`). Changes refuse when any `HERMES_*`
variable is set or any ancestor process is Hermes, and need a fresh code typed on `/dev/tty`; `swarmctl` and
SKILL.md expose none of it. `enroll <key-id> <pub-hex> --profile P...` checks the key is a prime-order point
and that neither the ID nor the key was ever enrolled. `revoke` is permanent and immediate. `mode required`
needs an active device; `mode legacy` is the only way back (explicit local recovery). No policy key,
environment variable or file re-enables v1. Bot profiles share the Unix account that owns `control.sqlite`
and the skill files, so this keeps model turns away from the tool and leaves an audit trail; it is not a
boundary against a hostile shell on the box. The operator CLI refuses key IDs starting with `TEST-`
because their fixture seeds are public. No CLI flag or environment variable bypasses this refusal;
tests enroll those keys only through the library function.

Tests: `sim/test_device_approvals.py` (every P5a vector through the real box, replay across restart, kill
mid-transaction, concurrent consume, revoke, cutover, host unreachable, Hermes byte-identical) and
`sim/test_device_enrollment.py` (operator guard, enrollment rules, corrupt state, read/challenge rules).

## P5d iOS managed approvals (device-signed only)

The P5c client now lives in SwarmHubCore (`Sources/SwarmHubCore/Approvals/`): `JSONValue`, `ManagedRecord`,
`ManagedControlError`, `DeviceApprovalJSON`, `DeviceApprovalWire`, `DeviceApprovalIdentity` (+ `DeviceApprovalKeychain`),
`DeviceApprovalSettings` and `DeviceSignedApprovalClient`. The Mac keeps its names through typealiases in
`Sources/AgentApp/Approvals/DeviceApprovalCore.swift`; its QA boundary and test-run guard are passed in as
`DeviceApprovalEnvironment.mac`, and v1 (`ManagedRemoteControl`) stays in the Mac app only. Wire bytes, key IDs
(`mac-` prefix), Keychain service, defaults keys and fixtures are unchanged.

iOS adds `ManagedApprovalStore`, `ManagedApprovalViews` and `DeviceApprovalSetupView` in `Apps/iOS/Sources/`. Each
phone/box pair gets its own key (`ios-` prefix) enrolled by the operator as above. The Settings row shows the key and the
enroll command; after `mode required` on the box, the user confirms the cutover on the phone (sticky, no way back in
the app). `ManagedApprovalScope` then reads approval fences (notifications only) from assistant messages of profiles on
device-required boxes and routes each to the connected decider profile; a card appears only for a pending record the
box returns over the signed `receipt` read. Boxes without a confirmed cutover show no managed section at all. Decisions
use `ManagedApprovalFlow.decide`: re-read, adopt any committed receipt, else challenge → sign → decide → receipt; a lost
acknowledgement keeps the attempt locked until a receipt or box-observed expiry settles it. Native Hermes approvals
(`MobileStore.resolve`) are unchanged.

**P5d2 (review gaps).** The phone's confirmation is only a local opt-in that lets it send signed reads to a box. What
it shows and decides follows the mode the box reports (`DeviceApprovalChecks.deviceRequiredOnly`, used only by
`ManagedApprovalFlow`): every non-gone receipt read and every challenge must say `mode: "required"`, checked before
anything is adopted, cleared or signed. `legacy`, a missing mode (boxes before skill 1.4.3) or any other value throws
`notDeviceRequired`; the store then drops every card of that box and hides the managed section until a later read
reports `required` again. Reported modes are kept in memory only, so after launch every box starts hidden. The refresh
runs from the Approvals list (`.task`, pull to refresh), so a hidden section is still re-checked. Skill 1.4.4
invalidates every outstanding challenge atomically on an actual mode switch, including challenges issued before the
update. A subsequent decision rejects with `mode_changed`, consumes nothing and records no decision or receipt; the
operation stays pending for the current mode’s normal path. Switching back cannot revive an invalidated challenge;
setting the same mode leaves challenges valid, including the Mac’s legacy-mode challenges. The phone shows
"Not accepted, box mode changed", clears the refused attempt and drops the box’s cards until a fresh read. It never
retries or re-signs automatically. Invalidation marks are pruned with their challenge rows.

A receipt another enrolled device committed (for example the Mac) resolves the phone's card as "Decided on another
device". It must pass the same structural receipt checks under that device's key ID (`[A-Za-z0-9._-]{1,64}`, not the
phone's), for this origin, decider profile and task, with the v2 fingerprint of the stored spec. When the phone holds an
uncertain attempt, the receipt must also match that attempt's origin, runtime, profile, task, gate and fingerprint
under a different nonce; the attempt is then cleared, because the box keeps one receipt per task and the phone's nonce
can no longer commit. A receipt that carries the phone's key ID still needs the phone's exact attempt and message. The
other device's message digest cannot be recomputed by the phone; like every v2 read, the answer is authenticated by
TLS to the configured origin and the request digest (the box holds no signing key). The Mac keeps `.compatible`: no
mode requirement and only its own receipts, exactly as in P5c. Tests: `sim/test_device_mode_reads.py` (Linux, real box)
and `ManagedApprovalModeTests` (Mac).

No shared-key path reaches the iOS target. `scripts/check-ios-approvals.py` runs as the first build phase of the
generated Xcode project and fails on HMAC/SymmetricKey, the v1 domain, endpoint or header, the Mac v1/local clients,
`swarmctl`, Hermes key-store use in approval files, project files outside `Apps/iOS/Sources`, or a stale project.
`--binary <app executable>` scans a built binary. Tests: `scripts/test_ios_approval_boundary.py` (Linux) and the
SwarmHubCore suites `DeviceApprovalCoreTests`, `ManagedApprovalFlowTests`, `ManagedApprovalScopeTests`,
`IOSApprovalBoundaryTests` (Mac).
