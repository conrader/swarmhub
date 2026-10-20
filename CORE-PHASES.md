# Plan B implementation phases

Source: `CORE-PLAN.md` (plan B, approved 2026-10-20, see its "Decision (Oct 20, 2026)" section). Baseline checkout `749d826`. This file divides plan B's migration (§8, steps 0–8) into phases. Each phase is sized for one coding job and lists its goal, files and components, acceptance tests, dependencies, and whether Konrad has to approve it. Nothing here has been built or run yet. Every acceptance line is a test the coding job must add and run.

## Rules for every phase

- **Hermes is never altered.** No phase writes a Hermes file, binary, configuration or service unit, and nothing restarts Hermes. Box-side code writes only to the profile's `skills/swarmhub/`, the updater's own state directory, and (bootstrap only, by the operator) the admin-owned updater location. Every box-side phase's acceptance includes a test that the job left Hermes files byte-identical (temp fixture tree; `Tests/Fixtures/hermes_v0.21.7_server.py` is the available stand-in).
- **Direct app ↔ box routing stays as it is.** No phase adds a runtime dependency on the update service. Every consumer phase includes a "host unreachable → no behaviour change" test.
- **Test keys only until P1b.** Fixture keys come from fixed seeds, have a `key_id` prefixed `TEST-`, and live only under `Tests/Fixtures/release-bundles/`. (The existing `Tests/Fixtures/bundles/` belongs to template import and is a different thing.) Release builds must reject `TEST-` keys (P2c).
- **Existing suites stay green**, at least `sim/test_remote_approvals.py`, `scripts/test_*.py`, `Tests/AgentAppTests/ManagedRemoteControlTests.swift` and the shell suites in `Tests/Scripts/`. Source files stay at 500 lines or fewer.
- **Where tests run.** Python and shell tests run on this Linux server. Swift (SwarmHubCore, AgentApp, iOS) cannot be built here and runs on the MacBook (`swift test`, `scripts/test-ios-core.sh`). A Swift phase is done only after its Mac run is green.
- **One branch per phase** (`swarmhub/core-<id>`), committed, reviewed, then merged into the integration branch.

Legend: **Now** = safe to do now (no production, no money, no real keys; test keys only). **K** = Konrad must approve the marked step.

## Phase list

| ID | Phase | Depends on | Now? | Konrad's OK needed for |
| --- | --- | --- | --- | --- |
| P0a | Schemas, JCS canonical form, signed test vectors | none | Now | none |
| P0b | Python verifier library | P0a | Now | none |
| P0c | Swift verifier in SwarmHubCore | P0a | Now | none |
| P0d | Python skill renderer + Swift golden renders | none | Now | none |
| P1a | Release tooling: build / sign / publish / republish | P0b | Now | none |
| P1b | Key ceremony: 2 recovery keys + hardware publishing key | P1a | no | **K: buy hardware, generate real keys, sign first key manifest** |
| P1c | Publish adapters: object store + GitHub mirror (code) | P1a | Now | none (fakes/local only) |
| P1d | Provision storage + CDN + domain, GitHub mirror repo | P1b, P1c | no | **K: accounts, money, DNS, first public upload** |
| P2a | Updater apply engine (stage, check, idle wait, swap, previous) | P0b, P0d | Now | none |
| P2b | Updater CLI, state, floors, protected checkpoint, confirm gate | P2a | Now | none |
| P2c | Baseline bundle + bootstrap package embedded in the app build | P1a, P2b | Now (test keys) | **K: release build signed with real keys** |
| P2d | Operator bootstrap installer + runbook | P2b, P2c | Now (container/VM) | **K: install on any real box** |
| P3a | Updater pull: fetch, channel, rollout bucket, compat, timers | P2b | Now (local static host) | none |
| P3b | Enable pull on the canary group of real boxes | P1d, P2d, P3a | no | **K: production deploy; picks the canary boxes** |
| P4a | Swift fetch client + local store (Mac + iOS core) | P0c | Now | none |
| P4b | Mac archive transport + `apply --staged` install path | P2b, P4a | Now (test boxes) | none |
| P4c | Mac per-box code-confirm UI + regression record | P4b | Now | none |
| P5a | Device-approval protocol + vectors | none (scheduled after P4) | Now | none |
| P5b | Box verifier, nonces, local enroll/revoke | P5a | Now (sim) | none |
| P5c | Mac device-signed client + cutover | P5b | Now (test boxes) | **K: enrolling his real boxes in device-required mode** |
| P5d | iOS managed approvals, device-signed only | P5b, P4a | Now (code, simulator) | **K: App Store submission** |
| P6a | Config store + typed schema + flags/kill switch (core) | P4a | Now | none |
| P6b | Mac + iOS config wiring (policy, prompts, copy) | P6a | Now | **K: iOS submission (with P5d/P7c)** |
| P7a | SDUI catalogue decoder + safety limits + fuzzing | P4a | Now | none |
| P7b | Mac SDUI renderer + first targets | P7a, P6a | Now | none |
| P7c | iOS SDUI renderer + first targets | P7a, P6a | Now | **K: App Store submission + review notes** |
| P8a | Channel tooling: promote, percent rollout, local pin, drill scripts | P1a, P3a, P4a | Now (local host, test keys) | none |
| P8b | Live drills: canary roll-forward, release-key rotation | P3b, P8a | no | **K: real keys, production channels** |

Ordering follows `CORE-PLAN.md` §8. P2 installs the whole protected updater without a timer, P3 turns its pull on, and P4 reuses the same `apply --staged`. P5 has no runtime dependency on the update service and only needs to land before config/SDUI rollout (P6b/P7b/P7c in production). Everything marked Now can start immediately in this order: P0a → (P0b ∥ P0c ∥ P0d) → (P1a ∥ P2a) → ….

## Phase details

### P0a: Schemas, JCS canonical form, signed test vectors (Now)
- **Goal:** Pin down the wire contracts from §2.1 so Swift and Python implement the same thing.
- **Touches:** new `docs/update-service/SCHEMAS.md`; `Tests/Fixtures/release-bundles/{keys,channels,bundles,blobs}/`, plus `vectors.json` listing each case and its expected verdict; `scripts/release/make_vectors.py` (fixed-seed TEST keys).
- **Design constraint:** no floating-point numbers anywhere in signed objects (`rollout_percent` and versions are integers), so JCS reduces to sorted keys + UTF-8 + minimal escaping and needs no number-formatting code.
- **Acceptance:** vectors cover valid, tampered byte, wrong key, unknown key, key past `not_after`, lower `keys.version`, lower `index.seq`, expired index, manifest hash mismatch, archive with `..`/absolute path/symlink/device/oversize/bad mode, a component labelled `data` whose archive holds code, and an incompatible `requires`. Regenerating from the seeds is byte-identical.
- **Konrad:** none.

### P0b: Python verifier library (Now)
- **Goal:** The §3.1 verification order as a library with no I/O policy: key manifest (1-of-2 roots) → index → manifest → component → archive rules.
- **Touches:** new `Resources/Updater/swarmhub_update/verify.py`, `jcs.py`, `ed25519.py`, `archive.py`; tests `Tests/Updater/test_verify.py`.
- **Ed25519 dependency:** box Pythons may lack `cryptography`, and the Xcode `python3` on macOS does not ship it. Vendor a verify-only RFC 8032 implementation inside the updater package so the bootstrap package (§3.5) is self-contained. Tests cross-check it against `cryptography` where installed. (Implementation choice inside the plan; flagged here, not a Konrad decision.)
- **Acceptance:** every P0a vector gives its expected verdict; the archive extractor never writes outside the target (path-traversal and symlink tests); stdlib-only import check passes.
- **Konrad:** none.

### P0c: Swift verifier in SwarmHubCore (Now, Mac run)
- **Goal:** The same verifier for the apps. It lives in SwarmHubCore because iOS links only that package.
- **Touches:** new `Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/{JCS,KeyManifest,ChannelIndex,BundleManifest,ArchiveRules}.swift` (CryptoKit `Curve25519.Signing`); `Packages/SwarmHubCore/Tests/.../UpdateVerifierTests.swift` reading the P0a vectors.
- **Acceptance:** every P0a vector matches the Python verdict; `swift test` for SwarmHubCore is green on the Mac; `scripts/test-ios-core.sh` is green.
- **Konrad:** none.

### P0d: Python skill renderer + Swift golden renders (Now, Mac run for goldens)
- **Goal:** The box renders skills exactly as `SkillLibrary.render` does (`Sources/AgentApp/BotManager/SkillLibrary.swift:122`, `:137`).
- **Touches:** new AgentAppTests test that writes golden renders for all four skills × sample profiles × coding orders into `Tests/Fixtures/release-bundles/renders/`; new `Resources/Updater/swarmhub_update/render.py`; `Tests/Updater/test_render.py`.
- **Acceptance:** Python output is byte-identical to every golden; a Swift test fails if the goldens drift from current `SkillLibrary.render` output.
- **Konrad:** none.

### P1a: Release tooling (Now)
- **Goal:** `build-bundle`, `sign`, `publish` (to a local directory), `republish <old> as <new>`, and `sign-keys` with a pluggable signer (file key for tests, hardware token later).
- **Touches:** new `scripts/release/{build_bundle,sign,publish,republish,keys}.py`; `scripts/test_release_*.py`. Bundle content is today's `Resources/Skills`, `Resources/BotManager` and policy defaults, each component classed `data` or `code` (§2.3), with `requires_component` declared wherever new data needs new code.
- **Acceptance:** a bundle built from `Resources/` verifies with P0b; republish produces version N+1 with N−1's blobs, unchanged; each `tool` and each skill with a script is classed `code`, everything else `data`, and the `code_bearing` flag is set exactly when a code component is present; publishing needs only the release key, not the roots; a signer that refuses `TEST-` keys can be enabled for production.
- **Konrad:** none.

### P1b: Key ceremony (K)
- **Goal:** Two offline recovery keys on separate hardware tokens stored apart, one publishing key on a hardware token, and the first root-signed key manifest.
- **Touches:** `docs/update-service/KEY-CEREMONY.md` (runbook, safe to write now); hardware signer adapter for `scripts/release/sign.py` (code safe now, tested with a soft-token emulator).
- **Before buying:** confirm the chosen token signs Ed25519 in the needed mode (§9 **[A]**, ~€100–150).
- **Acceptance:** P0b/P0c verify the real key manifest; the publishing key signs an index while both recovery keys are offline; the public keys are recorded in the repo; no private material is on disk.
- **Konrad:** **buying hardware (money), generating and storing the real keys (secrets)**. Only Konrad holds the tokens.

### P1c: Publish adapters (Now)
- **Goal:** Upload to an S3-compatible bucket (R2 or B2) and mirror to GitHub Releases, uploading blobs first, then manifests, then the index, with `Cache-Control` set per object type.
- **Touches:** `scripts/release/publish.py` backends; tests against a local fake (directory or MinIO in a container) and a `gh` dry-run.
- **Acceptance:** order and immutability are enforced (an existing blob is never overwritten); a partial upload never exposes an index that points at missing blobs; the mirror output verifies identically.
- **Konrad:** none.

### P1d: Provision hosting (K)
- **Goal:** Bucket + CDN on `updates.<domain>`, the GitHub mirror location, and the first upload of the baseline bundle.
- **Acceptance:** downloading again from both origins verifies; a host serving a modified blob or an old index is detected (§8 step 1).
- **Konrad:** **accounts and money (free tier expected, §9), DNS, first public upload.**

### P2a: Updater apply engine (Now)
- **Goal:** §3.4 apply: stage per profile, render (P0d), post-apply checks (frontmatter parses, scripts byte-compile, `--self-test` where present), wait for idle (no running `code-job` or `swarm_jobs.py` job, bounded deferral), atomic rename, keep `previous`, revert on failure.
- **Touches:** `Resources/Updater/swarmhub_update/{apply,stage,idle}.py`; `Tests/Updater/test_apply.py` on temp profile trees.
- **Acceptance:** a failed check leaves `current` byte-identical; a running job defers, then applies after it ends; open file handles in `current` survive the swap; a peer-plugin change sets `reload_pending` and never restarts anything; writes stay under `skills/swarmhub/` + state dir; Hermes fixture unchanged.
- **Konrad:** none.

### P2b: Updater CLI, state, floors, checkpoint, confirm gate (Now)
- **Goal:** `swarmhub-update {status,verify,apply --staged <dir>,apply,pin,check}`; persisted floors; enforcement of max(checkpoint, state) and revoked key IDs from the admin-owned pin file (§3.2); the decision-2 gate, per component: data components auto-apply, even in a bundle that also carries code; code components, and any data component that declares `requires_component` (directly or transitively) on a code component version not yet applied, stop at `pending_confirm` until `swarmhub-update apply` or the Mac confirm (P4c), then apply together. The applied version goes into the advertised SKILL.md description and the status file.
- **Touches:** `Resources/Updater/swarmhub_update/{cli,state,pins}.py`, `Resources/Updater/bin/swarmhub-update`; `M/scripts/swarmctl` (read-only status print); `Tests/Updater/test_cli.py`, `test_floors.py`.
- **Acceptance:** a lowered state floor stops at the checkpoint; a revoked key is refused even after the state is wiped; a code component never applies without confirm, while an independent data component in the same bundle does; a data component that requires a pending code component stays pending and applies with it after the confirm; `status` is readable by `swarmctl`; no network code in this phase.
- **Konrad:** none.

### P2c: Embedded baseline + bootstrap package (Now with test keys; K for real release)
- **Goal:** The app build embeds the signed baseline bundle and the updater package plus its SHA-256. Compiled code exports the package and shows the expected digest (§3.5). A fresh app runs offline from the baseline.
- **Touches:** `scripts/build.sh`, `scripts/package-release.sh`, `scripts/build-ios.sh` (baseline only, no updater on iOS); new `Sources/AgentApp/Updates/BootstrapExport.swift` + view; tests.
- **Acceptance:** the digest shown matches the packaged bytes; a release-configuration build fails if any pinned root or baseline signature uses a `TEST-` key; first launch offline uses the baseline; the existing Sparkle flow is unchanged.
- **Konrad:** **the first release build signed with real keys** (after P1b).

### P2d: Operator bootstrap installer + runbook (Now in container/VM; K for real boxes)
- **Goal:** A deterministic, non-model install of the updater, its dependencies and the pin file (roots, floor checkpoint) at an admin-owned location with no bot-account write access, on Linux and macOS.
- **Touches:** `Resources/Updater/install-bootstrap.sh`; `docs/update-service/BOOTSTRAP.md`; `Tests/Scripts/updater-bootstrap-test.sh` (container with a separate bot user).
- **Acceptance:** an altered package fails the hash check before anything executes; the bot user cannot modify the updater, the pins or the checkpoint, and the updater does not import from user-writable paths; a checkpoint-advance maintenance pass works; Hermes files are untouched.
- **Konrad:** **installing on any real box** (production).

### P3a: Updater pull (Now against a local static host)
- **Goal:** Outbound HTTPS fetch with `no-store`, no redirect off the allowlist, the rollout bucket `hash(install_id, bundle_version) mod 100`, compatibility-line selection including the Hermes range, stale index → keep running, and a systemd `--user` timer and launchd agent (both disabled by default).
- **Hermes version:** the plan left the source unread (§6 **[A]**). The job finds a read-only way to get it. If it cannot, Hermes is "unknown": components that declare a Hermes range are skipped with `incompatible: hermes`, and the rest apply.
- **Touches:** `Resources/Updater/swarmhub_update/{fetch,channel,compat}.py`, unit templates under `Resources/Updater/units/`; `Tests/Updater/test_pull.py` with `http.server` fixtures.
- **Acceptance:** host down → no change; bad signature → last good; mirror replay of an old index → rejected; expired index → `stale`, runtime unchanged; redirect to another host → refused; rollout percent is honoured deterministically.
- **Konrad:** none.

### P3b: Enable pull on the canary group (K)
- **Goal:** Turn the timer on for the canary boxes, one Linux box and one Mac box behind NAT, and check the open assumption that an atomic directory swap mid-turn does not disturb Hermes skill loading.
- **Acceptance:** §8 step 3 on real boxes; outbound-only access confirmed; a data update arrives without an app release; in a bundle that carries both, the data components apply and the code components wait for confirm.
- **Konrad:** **production deploy, and choosing which boxes form the canary group.**

### P4a: Swift fetch client + local store (Now, Mac run)
- **Goal:** Fetch at launch and every 6 h, using an ephemeral, no-redirect session (the `ManagedRemoteControl` discipline ported into SwarmHubCore); `current/` and `previous/` in Application Support (Mac) or the app container (iOS); persisted floors; a "updates stale since" state.
- **Touches:** `Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/{UpdateClient,UpdateStore}.swift`; tests with URLProtocol stubs.
- **Acceptance:** same failure matrix as P3a; iOS fetches only `mac|ios` data components; nothing is executed or loaded as code.
- **Konrad:** none.

### P4b: Mac archive transport + `apply --staged` (Now against test boxes)
- **Goal:** For bootstrapped boxes, the skill install sends verified, box-targeted archives plus signed metadata as opaque bytes, and a management turn stages them and invokes the updater by its fixed path. Un-bootstrapped boxes keep today's installer and do not claim verification.
- **Touches:** `Sources/AgentApp/Stores/AppStore+Skills.swift` (install path at `:82`/`:104`), `SkillLibrary.swift` (version read-back at `:166`), new `Sources/AgentApp/Updates/StagedInstall.swift`; tests.
- **Acceptance:** an altered archive is refused by the box updater and last good is kept; the Mac never unpacks or executes archives; the box render matches today's output for all four skills; success is read from the updater status, not from the model's reply.
- **Konrad:** none.

### P4c: Mac per-box code confirm + regression record (Now)
- **Goal:** Decision 2 in the UI. When a box has `pending_confirm`, show "Apply code update N on <box>" with the code components and any data components waiting on them. Confirming invokes `swarmhub-update apply` on that box. Also keep a per-box record of the highest version seen, which detects regressions (§3.2, detection only).
- **Touches:** new `Sources/AgentApp/Updates/BoxUpdateState.swift` + view; tests.
- **Acceptance:** no code applies without the per-box click; a regression is flagged; each confirmation covers exactly one box and one version.
- **Konrad:** none.

### P5a: Device-approval protocol + vectors (Now)
- **Goal:** A versioned approval domain binding box origin/runtime, profile, task, full operation fingerprint, gate, decision, and a one-use nonce with expiry issued by the box (§4).
- **Touches:** `Tests/Fixtures/device_approval_protocol.json` (next to `remote_approval_protocol.json`), `docs/update-service/DEVICE-APPROVALS.md`.
- **Acceptance:** vectors for valid, tampered field, replayed nonce, expired nonce, wrong box, wrong profile, revoked device, and a v1-only decision on a device-required box.
- **Konrad:** none.

### P5b: Box verifier, nonces, local enrollment (Now in sim)
- **Goal:** `swarm_remote.py` verifies device signatures against a local device list, consumes nonces transactionally, keeps receipt binding and idempotency, and has a device-required mode. Enroll and revoke are operator CLI actions, run outside model turns.
- **Touches:** `Resources/Skills/swarmhub-messages/scripts/swarm_remote.py` (split into modules to stay ≤500 lines), new `swarm_devices.py`; `sim/test_remote_approvals.py` + new `sim/test_device_approvals.py`.
- **Acceptance:** all P5a vectors; v1 still works on unenrolled boxes; once a box is device-required, nothing falls back to v1, flags included; works with the update host offline; native Hermes path untouched.
- **Konrad:** none.

### P5c: Mac device-signed client + cutover (Now on test boxes; K for real enrollment)
- **Goal:** A new Keychain-backed Ed25519 approval identity per device/box (following `OpenClaw/GatewayIdentity.swift`, but with separate keys), the signing client, and the cutover UI.
- **Touches:** `Sources/AgentApp/Models/ManagedRemoteControl.swift`, new `Sources/AgentApp/Approvals/DeviceApprovalIdentity.swift`; `Tests/AgentAppTests/ManagedRemoteControlTests.swift` + new tests.
- **Acceptance:** P5a vectors signed by the Mac verify in Python; v1 is unchanged before cutover; no OpenClaw key is reused; Secure Enclave backing is not claimed.
- **Konrad:** **switching his real boxes to device-required mode** (persistent security state).

### P5d: iOS managed approvals, device-signed only (Now in code; K for submission)
- **Goal:** iOS gets managed approvals for the first time, with no shared-key code path, shown only for device-required boxes.
- **Touches:** shared pieces moved into SwarmHubCore, `Apps/iOS/Sources/` new approval views; iOS tests.
- **Acceptance:** no shared-key symbols in the iOS target (build-time check); approvals hidden on boxes that are not device-required; the native Hermes approval path is unchanged.
- **Konrad:** **App Store submission.**

### P6a: Config store + flags/kill switch (Now)
- **Goal:** Typed `config.policy`, `config.prompts`, `config.copy` and `config.flags` read from the verified bundle, falling back to the compiled default per key.
- **Touches:** `Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/ConfigStore.swift`; tests.
- **Acceptance:** missing key → default; wrong type → default + logged reason; a kill-switch flag disables a key or view type; no update-service config can touch approval keys, approver lists, gate weakening or approval/secret endpoints (§4 denylist enforced in the decoder).
- **Konrad:** none.

### P6b: Mac + iOS config wiring (Now; K for iOS submission)
- **Goal:** Wire model defaults (`S/Models/ModelPolicy.swift:112`), coding order (`S/Models/CodingOrder.swift:30`), team policy (`TeamPolicy.swift:14`), the manager template through the existing `managerTemplateOverride` seam (`AppStore+Skills.swift:126`, `:157`), and copy.
- **Acceptance:** with no bundle, behaviour is identical to today (snapshot of resolved values); with a bundle, the values change without a build.
- **Konrad:** **the iOS build goes through App Store review** (batch with P5d/P7c).

### P7a: SDUI catalogue decoder + safety (Now)
- **Goal:** Catalogue v1 (§5.1) as strict decoders with size and depth limits, a closed action enum, typed predicates only, and no route to `operation_review` or `secret_entry`. Documents that fail to decode use the compiled fallback, and `critical` documents show "update required".
- **Touches:** `Packages/SwarmHubCore/Sources/SwarmHubCore/SDUI/`; decoder fuzz tests; golden documents in `Tests/Fixtures/release-bundles/ui/`.
- **Acceptance:** the fuzzer finds no crash or partial render; unknown component → fallback; URL actions are allowlisted and require confirmation; no `JSContext` or dynamic loading symbol in the target.
- **Konrad:** none.

### P7b: Mac SDUI renderer + first targets (Now)
- **Goal:** Native SwiftUI rendering of the catalogue. First targets are routine result cards and the routine create/edit forms (`S/Models/RoutineSchedule.swift:13`).
- **Acceptance:** golden snapshots; with no bundle, the compiled views are unchanged; kill switch → compiled view.
- **Konrad:** none.

### P7c: iOS SDUI renderer + first targets (Now; K for submission)
- **Goal:** The same catalogue and the same golden documents on iOS.
- **Acceptance:** snapshot parity with the Mac for the shared goldens; review notes describe each bundle-delivered capability (§5.3, guideline 2.3.1); re-read guideline 2.5.2 before submitting.
- **Konrad:** **App Store submission.**

### P8a: Channel tooling + drill scripts (Now with local host and test keys)
- **Goal:** `promote canary→beta→stable` (copy the index entry, bytes unchanged), percent rollout edits, local pin in the Mac app and `swarmhub-update pin`, and scripted drills: bad bundle → republish roll-forward, and release-key rotation via the key manifest.
- **Acceptance:** both drills pass end to end against the local host with test keys; promotion never rebuilds or re-signs blobs.
- **Konrad:** none.

### P8b: Live drills (K)
- **Goal:** Run the P8a drills on the real canary group with the real publishing key, including one release-key rotation signed by a recovery key.
- **Acceptance:** §8 step 8: every canary consumer recovers without an app build; a rotated-out key is refused fleet-wide.
- **Konrad:** **real keys, production channels.**

## Open items carried from the plan

- How to read the installed Hermes version (P3a, read-only; unknown → skip components that declare a Hermes range).
- Whether an atomic swap of `skills/swarmhub/` disturbs Hermes mid-turn (checked on real boxes in P3b).
- Hardware-token Ed25519 support and price (P1b, before buying).
- App Store guideline wording (P5d/P6b/P7c, before submitting).
