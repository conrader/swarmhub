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

First failure wins: trusted snapshot validity → strict JSON/envelope/field shape
(`schema_invalid`) → version/domain (`protocol_unsupported`) → local device
(`device_unknown`, `device_revoked`) → signature (`signature_invalid`) → exact
box/profile/device authorization/task/fingerprint/gate/pending state
(`box_mismatch`, `profile_mismatch`, `device_unauthorized`, `task_mismatch`,
`fingerprint_mismatch`, `gate_mismatch`, `operation_not_pending`) → nonce existence,
binding, unused status and time (`nonce_unknown`, `nonce_mismatch`,
`nonce_replayed`, `nonce_not_yet_valid`, `nonce_expired`) → `accept/ok`.
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
