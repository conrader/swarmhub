# Shared-core plan: an update service only (core7)

Baseline: detached `749d826` (`swarmhub/peer-delivery`), 2026-10-20. I worked from the source only. No app, test, installer or service was run, and nothing was provisioned. References are repository-relative `path:line`. Input: Konrad's direction of 2026-10-20 07:49 (`CORE-ADDENDUM.md`), which supersedes the core1–core4 runtime-backend design. **[A]** marks an assumption.

**Recommendation.** The "core" is a **signed release pipeline plus static hosting**. It is not a server in the runtime path:

```
 FRONTEND  Mac app (Sparkle) · iOS app (App Store)
   │  ── normal work, approvals, chat, routines: DIRECT to each box's Hermes, exactly as today ──┐
   │  ── pull only: channel index + bundles over HTTPS, verify against pinned keys ─┐             │
   ▼                                                                                ▼             ▼
 UPDATE SERVICE  static files on a CDN/object store              BOX  Hermes (never modified) + Swarm Hub
   signed key manifest, signed channel indexes,                     skills/tools; `swarmhub-update` pulls the
   content-addressed signed bundles. No accounts, no                same bundles over outbound HTTPS and applies
   sessions, no box credentials, no approvals.                      them atomically, keeping the last good version
        ▲
 RELEASE  Konrad's machine: build bundle → sign with release key (offline root delegates) → upload
```

Behaviour that today needs an app build moves into data bundles: skills, box tools, configuration, prompts and recipes, and server-driven UI (SDUI) definitions. Every consumer verifies a bundle against keys pinned to Konrad, keeps its last good version, and treats the update service as optional. **If the service is down, deleted or compromised, everything keeps running on the last good bundle. Only updates wait.** A compromised host can withhold updates. It cannot change behaviour, because it holds no signing key.

## 1. Current state and inventory

### 1.1 Topology today (kept)

- Clients talk **directly** to each box's Hermes HTTPS origin, using the profile's `API_SERVER_KEY` as a Bearer token (`Packages/SwarmHubCore/Sources/SwarmHubCore/HermesClient.swift:121`, `:125`). Sessions, messages, stop/steer and native approvals go through the same channel (`:41`, `:68`, `:90`, `:103`). This plan does not change it.
- Remote managed approvals go to the box's own origin through nginx at `/swarmhub/control/v1/`, which forwards to a loopback service (`Resources/Skills/swarmhub-messages/scripts/swarm_remote.py:214`–`:217`; `Resources/Skills/swarmhub-messages/SKILL.md:163`). They are authenticated with Bearer plus an **HMAC over the shared profile key** (`Sources/AgentApp/Models/ManagedRemoteControl.swift:17`, `:44`, `:45`; box check `swarm_remote.py:97`). **This Hermes managed-approval path has no device signing today.** Separately, OpenClaw already creates Keychain-backed Ed25519 device keys and signs payloads (`Sources/AgentApp/OpenClaw/GatewayIdentity.swift:36`, `:43`, `:49`). Its identity implementation is a possible reuse source for the required approval phase (§4, §8 step 5), with separate keys and protocol binding.
- **iOS has no managed approvals today.** The iOS project links only the `SwarmHubCore` package (`Apps/iOS/SwarmHub.xcodeproj/project.pbxproj:34`–`:35`); `ManagedRemoteControl` and the managed-action store exist only in the Mac sources (`Sources/AgentApp/Models/ManagedRemoteControl.swift`, `Sources/AgentApp/Stores/AppStore+ManagedActions.swift`). iOS offers native Hermes approvals only ("manual approvals", `Apps/iOS/Sources/RootView.swift:74`; `HermesClient.resolve`, `HermesClient.swift:103`). So only the Mac has a shared-key managed-approval path to migrate.
- The Mac app updates through Sparkle from GitHub releases. The feed is `.../releases/latest/download/appcast.xml`, pinned by `SUPublicEDKey` (`Resources/Info.plist:54`–`:57`), and the tooling is `scripts/generate-appcast.sh` and `scripts/sparkle-tools.sh`. Konrad already runs one Ed25519 release-signing flow. iOS targets 18.0 (`Apps/iOS/SwarmHub.xcodeproj/project.pbxproj:44`) and goes through App Store review.
- **Skills ship inside the app.** `SkillLibrary.bundled` reads `Resources/Skills/<name>/SKILL.md` from the app bundle (`Sources/AgentApp/BotManager/SkillLibrary.swift:51`, `:64`). The versions in this checkout are coding 1.3.12, messages 1.3.9, manager 1.2.0 and feedback 1.0.0 (`Resources/Skills/*/SKILL.md:4`). Install is a **management turn**: the app sends the manager bot heredoc shell commands, and the model runs them (`Sources/AgentApp/Stores/AppStore+Skills.swift:82`, `:104`). The installed version is read back from the advertised description (`SkillLibrary.swift:166`). A skill fix therefore needs an app release, and nothing on the box checks the integrity of what the model wrote.
- The app has no remote config or content fetch. The only network origins in `Sources/` are user boxes, integrations and the Sparkle feed.

### 1.2 Inventory: what moves into bundles

S/ = `Sources/AgentApp/`, M/ = `Resources/Skills/swarmhub-messages/`.

| Area | Today | Bundle component | Stays compiled / on box |
| --- | --- | --- | --- |
| Skills | `Resources/Skills/*` in the app, installed by a model turn (`AppStore+Skills.swift:82`) | `skill` (SKILL.md + files, per-profile templating as `SkillLibrary.render`, `:122`) | Rendering engine, profile validation |
| Box tools | `M/scripts/*` (`swarm_policy.py`, `swarm_jobs.py`, `swarm_remote.py`, `peer-runtime.py`, `swarmctl`), `swarmhub-coding/scripts/code-job` | `tool` (code-bearing, box-only) | Hermes; root-owned proxy config |
| Manager recipes, prompts | `Resources/BotManager/manager-hermes.md`, `recipes/*.md`; `managerTemplateOverride` already exists as a seam (`AppStore+Skills.swift:126`, `:157`) | `config.prompts` | Fence parser `S/BotManager/SwarmhubBlock.swift` until SDUI covers it |
| Policy defaults | Model defaults `S/Models/ModelPolicy.swift:112`, coding order `S/Models/CodingOrder.swift:30`, team policy `Packages/SwarmHubCoordination/.../TeamPolicy.swift:14` | `config.policy` (typed values, no logic) | The code that evaluates them |
| Feature flags, copy | Compiled constants | `config.flags`, `config.copy` | Features the build cannot render |
| Cards, forms, flows | Draft/approval cards `S/Models/ChatCards.swift:16`, `S/Views/MarkdownContent.swift:100`; routine forms `S/Models/RoutineSchedule.swift:13` | `ui` (view documents from a fixed native catalogue, §5) | `operation_review`, `secret_entry`, chat transcript, navigation |
| Approvals, keys, secrets | Mac → box managed (HMAC), Mac/iOS → Hermes native (Bearer) (§1.1); Keychain `S/Stores/KeychainStore.swift:21` | **Never** | Entirely local (§4) |

## 2. Release bundles, channels, rollback

### 2.1 Objects on the update service (all static, all immutable except indexes)

1. **Key manifest** `keys.json`, signed by the **root keys** (decision 1). It lists release keys with `{key_id, ed25519_pub, roles: [bundle, index], not_after}` and carries a monotonic `version`. Root public keys are compiled into the apps and installed into the box updater's protected pin file by the non-model bootstrap (§3.5). A key manifest is valid only when signed by the threshold of pinned roots (recommendation: 1 of 2 roots, both offline).
2. **Bundle manifest** `bundles/<version>.json`, signed by a release key. Its fields: `{schema:"swarmhub/bundle/1", version (monotonic integer), label (semver), created, code_bearing, requires, components[]}`. Each component is `{kind: skill|tool|config|ui, class: data|code, name, version, targets: [box|mac|ios], sha256, size, path, requires, requires_component}`; `requires_component` lists other components by name and minimum version (§2.3, §6). `code_bearing` is true exactly when at least one component has class `code`. The signature covers the RFC 8785 (JCS) canonical bytes, with shared Swift/Python test vectors.
3. **Blobs** `blobs/sha256/<hash>`: the component archives, content-addressed. A blob is never overwritten.
4. **Channel index** `channels/<name>.json`, signed by a release key. Its fields: `{channel, seq (monotonic), issued, expires, lines[]}`. Each compatibility line (§6) is `{requires, bundle_version, manifest_sha256, rollout_percent}`.

Channels are `stable`, `beta` and `canary`. A box or app subscribes to one channel and may pin a bundle version locally. Promotion copies an entry from one index to the next. The bytes do not change, so what canary tested is exactly what stable gets.

### 2.2 Rollout and rollback

- **Staged rollout.** Every install draws a bucket from `hash(install_id, bundle_version) mod 100` and applies the bundle only when the bucket is below `rollout_percent`. This needs no telemetry and no server state. The `install_id` is random and local.
- **Publisher rollback = roll forward.** To undo bundle N, Konrad republishes N−1's content as a new version N+1 and points the index at it. Version numbers only increase, so anti-rollback (§3.2) never has to tell a legitimate downgrade from an attack. A tooling step does this (`republish <old> as <new>`), with no hand editing.
- **Local rollback.** Each consumer keeps `current` and `previous` (the last good). If apply or the post-apply check fails, it reverts to `previous` locally and reports `apply_failed`. A user or operator can also pin `previous` from the app or `swarmhub-update pin`. A local pin is a choice the device makes and does not lower the trust floor.
- **Kill switch.** A signed `flags` entry can disable one SDUI view type or one config key, so the compiled fallback is used without a new bundle (§5.4).

### 2.3 Bundle and component classes

**Component classes.** The apply policy works per component, and the component is the unit of apply. Every component carries a signed `class`. **Data** components hold settings and config (policy defaults, prompts, copy, flags) and UI definitions: `config` and `ui` kinds, plus a `skill` whose archive holds Markdown text only. **Code** components hold anything that executes on a box: every `tool`, and every `skill` whose archive contains a script or any other non-Markdown file. Such a skill is code as a whole, SKILL.md included. Verifiers re-derive the class from kind and archive contents and reject a component labelled `data` whose content is code, a data file with an executable mode, and a `code_bearing` flag that does not match the components. A **code-bearing** bundle is one with at least one code component; it may also carry data components, and those are not held back by the code beside them (decision 2). A data component that declares `requires_component` on a code component waits with it (decision 2). App **consumption** is data-only: the `mac` and `ios` targets get `config` (including prompts) and `ui`, interpreted by compiled app code. Separately, the Mac may **transport** signed, `box`-targeted skill/tool archives as opaque bytes. It never unpacks them into app resources, loads or executes their scripts; the box independently verifies them before extraction and execution (§3.3–3.5). iOS has no archive transport role in this plan.

## 3. Fetch and verify (apps and boxes)

### 3.1 Verification order (identical in Swift and Python)

1. Fetch `keys.json`. Verify the root threshold against the pinned roots, and reject a `version` below the highest persisted. Persist the new version.
2. Fetch `channels/<name>.json`. Verify it against a current release key holding role `index`. Reject `seq` below the highest persisted. If it has expired, **keep the last good bundle**, mark updates "stale" and continue running.
3. Pick the highest line whose `requires` matches this consumer (§6) and whose rollout includes it. Fetch the bundle manifest and check its SHA-256 against the index entry, then its signature against a release key with role `bundle`.
4. For local apply, fetch only components targeted at this consumer. Check size, then SHA-256, then strict archive rules: relative paths only (as `SkillLibrary.isSafeRelativePath`, `SkillLibrary.swift:98`), no symlinks or devices, a mode allowlist, and per-file and total size limits. The Mac transport exception (§2.3) checks signed metadata, size and hash for the destination box's components, then forwards opaque archives plus the signed key manifest, index and bundle manifest; the box repeats verification against its own pins, persisted floors and compatibility before extraction.
5. Stage into a new directory, run the post-apply checks (§3.3), then switch atomically. Record `{bundle_version, manifest_sha256, applied_at}`.

**Fail closed means "do not apply", never "stop working".** A bad signature, unknown key, hash mismatch, lower `seq` or `version`, expired index, malformed archive, incompatible `requires` or storage error leaves the consumer on its last good bundle and surfaces the reason. No error path deletes the running version. A first run with no network uses the **baseline bundle embedded in the app build**: the compiled-in skills, config and UI that ship today, signed by the same pipeline. A fresh app therefore never needs the service.

### 3.2 Anti-rollback and freeze

The persisted `keys.version`, `index.seq` and applied `bundle.version` stop a mirror from serving old signed content (rollback). The index `expires` (default 7 days **[A]**) bounds how long a mirror can silently withhold a newer index (freeze). After expiry, the app shows "updates stale since <date>" and the box reports it. **Runtime is unaffected.** Release keys rotate by publishing a new key manifest. A release-key compromise is answered by a root-signed key manifest that drops the key, followed by a higher-`seq` index. A root compromise needs a new app build and a new box pin (§7).

**Box floors are bot-writable.** The box updater runs on the bot account's user timer (§3.4), so its state directory, which holds these floors, is writable by the bot account (`M/SKILL.md:155`: one Unix account, no isolation from a bot with shell access). A bot can lower `keys.version`, `index.seq` or `bundle.version`, after which the verified apply path (timer or `apply --staged`) accepts older, still validly signed content, including a key manifest that predates a revocation. Mitigations:
- **Protected checkpoint.** The admin-owned pin file (§3.5) also records `min_keys_version`, `min_index_seq`, `min_bundle_version` and revoked `key_id`s. Bootstrap writes them and every operator maintenance pass advances them, outside the model. The updater enforces max(checkpoint, state) and refuses revoked keys from the checkpoint, so nothing the bot writes goes below it.
- **Signed freshness, re-derived without writable state.** Index `expires` (7 days **[A]**) and release-key `not_after` are checked against the system clock, which the bot account cannot set. Keep `not_after` short (≤90 days **[A]**, renewed by a root-signed key manifest). A lowered floor then re-admits only indexes signed within the last `expires` window and keys still inside `not_after`.
- **App-side record (detection only).** The Mac keeps, per box, the highest versions it has seen in updater status and flags a regression. The status is bot-writable too, so this catches state loss and naive rollback, not a bot that also rewrites status; on a local box under the same Unix account the record is writable as well (the Mac app is not sandboxed: `Resources/SwarmHub.entitlements`).

**Still unprotected:** between checkpoints, a bot can roll the verified path back to any content that is still in date (for a revoked key: until its `not_after` or the next checkpoint, whichever is first) and report it as verified. This adds little to what it can already do, since it can rewrite installed skills directly (§3.5). Isolating the floors fully needs the updater and its state under a separate service account, which this plan does not require.

### 3.3 Apps

- **Mac and iOS** fetch at launch and then every 6 h **[A]**, with `no-store` and no redirect to a non-allowlisted host, reusing the `ManagedRemoteControl` no-redirect, ephemeral-session discipline (on iOS, ported into `SwarmHubCore`, since that type is Mac-only). Verified `config` and `ui` live in Application Support (Mac) or the app container (iOS), as `current/` and `previous/`. Every value read falls back to the compiled default when its key is absent or fails schema validation.
- **Mac as archive transport.** After the box completes the non-model bootstrap (§3.5), the Mac can forward verified, box-targeted archives instead of today's raw skill files. A management turn may write the opaque archive and signed metadata into staging and invoke the trusted updater by its fixed absolute path with `apply --staged <dir>`. The box repeats §3.1 verification and renders templates there; the Mac never executes the archive. An altered archive is rejected by that updater. A model reply alone is not proof of install success; use the updater's status, subject to the account boundary in §3.5. Before bootstrap, retain today's installer with its existing limitations; do not claim verified staged installation.
- Post-apply checks: every UI document in the bundle decodes against the app's catalogue, and config types validate. A failure reverts to `previous`.

### 3.4 Boxes: `swarmhub-update`

- A Python updater installed separately from mutable skill/tool bundles by §3.5. It runs unprivileged from a user-level timer (systemd `--user` on Linux, launchd agent on macOS) every 6 h **[A]**, plus `swarmhub-update check` on demand. It uses outbound HTTPS only, opens no listener, holds no Hermes key and makes no Hermes call. It writes only under each profile's `skills/swarmhub/` (`SkillLibrary.swift:148`, `:152`) and its own state directory.
- Root pins, the floor checkpoint (§3.2) and updater code are protected from the bot account; channel selection and update state remain local and bot-writable. Ordinary bundles cannot replace the updater, its dependencies or root pins. Their maintenance uses the same non-model verification path as bootstrap.
- **Apply:** stage per profile with templating identical to `SkillLibrary.render`. The Python port is tested against Swift-rendered golden files. Then check: frontmatter name and version parse, scripts byte-compile, and a `--self-test` per tool where one exists. Wait for idle: no running `code-job` or swarm job (`swarm_jobs.py`), and defer up to a bound, then retry. Finally, rename the directory atomically and keep `previous`. Processes that are already running keep their open files.
- **Plugin reload.** Changes to the peer plugin (`peer-runtime.py`) need a gateway reload, as today ("mention that a reload is needed", `AppStore+Skills.swift:110`). The updater never restarts Hermes. It marks the box `reload_pending`, and the app shows that state.
- **Reporting to the app** uses existing local channels only. The updater writes the applied version into the advertised SKILL.md description, which the app already reads (`SkillLibrary.swift:166`), and into a status file that `swarmctl` can print. The update service receives nothing back.
- **Remote boxes** run the same updater and use the same operator bootstrap (§3.5), via their console or an existing authenticated SSH session. Routine updates need only outbound 443 to the CDN; no new inbound update listener is required.

### 3.5 Bootstrap trust: outside the model

- **Trust starts with the signed app build and an operator-controlled box.** The app build embeds the baseline updater package (including its verifier dependencies and root-key list) and its SHA-256. Compiled app code checks that digest before export and displays the expected digest. Neither the expected hash nor the root keys may come from chat, a management turn or the update host.
- **Required deterministic install.** At the box console or over authenticated SSH, the operator transfers that package, checks its SHA-256 with an existing trusted OS tool against the app-displayed value, and only then extracts/installs it. Install the updater, dependencies and pins at a fixed administrator-owned location, with no bot-account write access and no imports from staging or user-writable module paths. This step runs outside Hermes and the model; it requires no Hermes modifications. A management turn cannot establish bootstrap trust.
- **Before bootstrap:** today's model-mediated skill install has no cryptographic integrity guarantee on the box. A signed archive does not help if its verifier or pins are substituted. **After bootstrap:** the trusted updater rejects altered archives or metadata before applying them; the model can still fail to deliver or invoke it. This protects the verified apply path, not arbitrary shell activity: the bot account can still rewrite installed skills, user-owned update state (including anti-rollback floors above the protected checkpoint, §3.2) or status outside that path (`M/SKILL.md:155`). It does not protect a compromised app/OS/admin account, or establish that existing skills were clean. Record bootstrap as complete only from the operator's deterministic check, never a model's assertion.

## 4. Approvals, keys and secrets stay local

- **No update-service path carries an approval, a decision, a secret, a Hermes key or a transcript.** It has no accounts and no write API. App ↔ box routing stays direct: chat, native approvals (`HermesClient.swift:103`), managed approvals over the box's own `/swarmhub/control/v1/` with no-redirect and receipt binding (`swarm_remote.py:100`, `:114`, `:151`), Mac-local secret intake (`S/Stores/AppStore+ManagedActions.swift:137`), and Keychain storage. “Local” means within the app ↔ destination-box trust relationship, including remote boxes at their own origins.
- **Required device-signing phase (§8 step 5).** Today only the Mac sends remote managed approvals, using shared-key Bearer + HMAC; keep that v1 scheme for the Mac until the replacement ships and a box is explicitly enrolled. The **Mac migrates** from shared-key to device-signed. **iOS gets managed approvals for the first time, device-signed only**: a new compiled feature (App Store review) with no shared-key code path, ever. Ship the signing clients and a Swarm Hub box-side verifier independently of the update service. Recommend Keychain-backed Ed25519 identities using the existing OpenClaw implementation as a reuse candidate (§1.1), with new approval-specific keys per device/box; do not reuse OpenClaw private keys or connect payloads, or claim Secure Enclave backing for them.
- **Local enrollment and verification.** An operator enrolls/revokes device public keys on each box outside model turns; no central roster or release bundle can authorize devices. Device signatures bind a versioned approval domain, box origin/runtime, profile, task, full operation fingerprint, gate, decision and a box-issued one-use nonce with expiry. The box verifies against its local device list, consumes the nonce transactionally and retains receipt binding/idempotency. Enrollment and recovery work through the box console; normal decisions go directly app → box, even when updates are unavailable.
- **Cutover without silent downgrade.** Unenrolled boxes continue Mac v1 during rollout. iOS shows managed approvals only for boxes enrolled in device-required mode, so its signatures never coexist with shared-key authority on the same box; on other boxes iOS keeps native approvals only. Once a box is enrolled in device-required mode, shared-key-only decisions and revoked devices are rejected; failures or feature-flag changes must not fall back to v1. Recovery requires an explicit local operator action. This phase covers Swarm Hub managed approvals on local and remote Hermes boxes. Native Hermes approvals retain their existing direct Bearer API and are not claimed to be device-signed; Hermes itself is never modified.
- **What bundles may never do:** add or replace approval keys or approver lists, change gate classes to weaker ones without a local confirmation, ship `operation_review` or `secret_entry` UI, or carry endpoints that receive approvals or secrets. Box tools in a bundle keep their existing gates (`swarm_policy.py:159` `validate_spec`). A bundle that edits the gate code carries it as a code component, which waits for the local confirmation under decision 2.
- A malicious signed bundle (key compromise) could still ship hostile box tools or prompts. That is the main residual risk. Mitigations: §7, plus decision 2.

## 5. Server-driven UI (signed data, rendered natively)

### 5.1 Model

`ui` components are **view documents**: versioned JSON trees drawn from a fixed native catalogue, with bindings to data the app already has (a routine result, a pending action record) and **actions that map to existing app commands**. There is no backend to post to. Catalogue v1: `text` (plain or markdown subset, no HTML), `badge`, `key_value`, `list`, `card`, `form` (typed fields: `text`, `multiline`, `choice`, `toggle`, `date`, `schedule`, `file_pick`), `button` (with `action` from a closed enum of local commands), `flow`, `progress`, `diff_preview`. `operation_review` and `secret_entry` stay **compiled screens**, so no document can describe them.

First targets: routine result cards, routine create and edit forms, Draft Send card copy and layout, onboarding and connect-box flows, and settings panes. Precedent: managed records already render field by field from full-spec JSON (`S/Models/ManagedControl.swift:66`).

### 5.2 What ships without a build vs what needs one

**Bundle only:** skill and tool fixes; prompts and recipes; policy defaults; copy; flags for features the build already has; new cards, forms and flows built from existing components and existing local actions.
**Needs a build:** a new component or local action; new native capability (notifications, widgets, files, camera); anything touching keys, signing or approvals; navigation shell; the chat transcript; accessibility or layout fixes inside a component; a new Hermes API call.

### 5.3 App Store limits

- Guideline 2.5.2 bars downloading code that adds or changes features. View documents and config are **data** read by compiled code. Rules: no JS, WASM or Lua, no `JSContext`, no dynamic library or bytecode loading. The catalogue has no expressions or loops; conditions are limited to closed, typed predicates on local data (`exists`, `equals` a literal). `tool` components never target app consumption; they execute only on boxes. The Mac's opaque transport role (§2.3) does not enable app execution; iOS fetches only its data components. **[A]** This reflects the guideline text as known in mid-2026; re-read it before submitting.
- Guideline 2.3.1 (no hidden features): when a bundle adds a user-visible capability, describe it in the next build's review notes and keep the review/demo setup at parity. Do not unlock, after review, something reviewers could not see (for example, real outbound Draft Send).
- The Mac app is Sparkle-distributed and notarized, so App Store review does not apply. It follows the same rules so both apps render the same documents.

### 5.4 Safety of SDUI

Even signed documents are treated as untrusted input, because they are exposed if a key is compromised. Rules: strict decoding with size and depth limits; strings are rendered as text, never markup; URLs open only from an allowlist and only after confirmation; documents cannot deep-link into approval or secret screens; and no document can read the Keychain, files or notifications except through a declared local action. A document that fails to decode is replaced by the compiled fallback, never shown partially. A view marked `critical` shows "update required" instead.

## 6. Compatibility and versioning

Four version axes, each declared and none inferred:

| Axis | Declared by | Example |
| --- | --- | --- |
| App build | App: `app=0.6.2`, `ui_catalog=1.3`, `config_schema=2`, `platform=ios` | Compiled constants |
| Bundle | Manifest `version` (monotonic) + `label` | `412` / `2026.10.3` |
| Component | `requires` per component | `ui_catalog>=1.2`, `hermes>=X,<Y` |
| Hermes | Box updater reads the installed Hermes version **[A: the command or file to read was not inspected]** | Recorded in status |

- The index publishes **parallel compatibility lines**, for example one for `ui_catalog 1.x` and one for `2.x`. Older apps keep getting fixes on their line for at least 2 app releases **[A]** after a major bump.
- Inside a line, changes are additive only. A component the consumer cannot satisfy is skipped, and the previous version of that component stays. Other components still update, because components are independent within a bundle unless one declares `requires_component`.
- Box side: components declare a Hermes range. Outside the range, the updater keeps the last good version and reports `incompatible: hermes`. Hermes is never upgraded or patched by this system.
- App side: each component declares `since`. A document that uses an unknown component carries a `fallback` (text plus "Update the app").
- Conformance suite in the repository, next to the existing fixtures (`Tests/Fixtures/remote_approval_protocol.json`): signed-bundle vectors (valid, tampered, wrong key, lower seq, expired index), golden view documents with snapshot tests on Mac and iOS, decoder fuzzing, and Swift↔Python render parity for skills.

## 7. Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Release key compromise | Hostile skills or tools on every box that auto-applies; hostile copy in apps | Offline roots delegate to a release key on hardware; staged rollout (canary first); decision 2 local confirm for code; key-manifest revocation; anti-rollback |
| Root key loss | No new release keys | Two roots, stored apart; losing both needs an app build plus a box re-pin (documented, rare) |
| Update host down or blocked | Updates wait; index eventually "stale" | No runtime effect by design; a mirror is any static host (indexes are signed) |
| Mirror replays old or withholds new | Rollback or freeze | Persisted `seq`/`version`; index `expires` |
| Bot lowers box anti-rollback floors (bot-writable state) | Verified apply accepts older in-date content or a key revoked since the last checkpoint | Admin-owned floor checkpoint; index `expires` and short key `not_after` against the system clock; Mac regression record (detection only). Residual between checkpoints (§3.2) |
| Bad but validly signed bundle | Fleet regression | Canary → beta → stable; percent rollout; local `previous`; roll-forward republish |
| Swap during a running job | Mixed tool versions mid-job | Idle wait plus directory rename; deferral bound |
| Skill render drift Swift ↔ Python | Different SKILL.md on box vs app view | Golden render vectors; one renderer per release, tested both sides |
| Plugin change needs reload | New peer behaviour not active | `reload_pending` shown; operator reload; never auto-restart Hermes |
| App Store rejection | iOS build blocked | Data-only catalogue, no interpreters, review notes per capability |
| Model alters bootstrap or staged input | A substituted verifier/pin would accept tampering | Non-model bootstrap from signed-app digest; protected updater/pins; independent box verification (§3.5) |
| Bot account rewrites installed skills or update state | Bypasses verified apply or its recorded status | Still outside the guarantee under today's one-account boundary (`M/SKILL.md:155`); protected bootstrap does not isolate all runtime files |
| Scope creep back into a runtime backend | Lost "core down = fine" | Hard rule: the service is static files with no write API; any feature needing a live server is a scope change for Konrad |

## 8. Phased migration (current release keeps working at every step)

Rules: no Hermes file is touched; app ↔ box routing stays direct. Mac v1 remote approvals remain unchanged through steps 0–4 and on unenrolled boxes during step 5. Update features ship behind flags with compiled fallbacks. Step 5's device-required enrollment is persistent security state: disabling a flag cannot restore shared-key approval authority. Device signing is scheduled after step 4 and before config/SDUI rollout, with no runtime dependency on the update service. Ordering: step 2 installs the whole protected updater (verifier, `apply --staged`, `status`, pins, floor checkpoint) but no timer; step 3 turns on its pull; step 4's Mac transport reuses the same installed `apply --staged`, so no step depends on a later one.

| Step | Change | Acceptance (proposed, not run) |
| --- | --- | --- |
| 0. Contracts | Manifest, index and key-manifest schemas; JCS vectors; Swift and Python verifiers as libraries with no UI; golden SKILL.md renders from today's `SkillLibrary.render` | Vector suite green in both languages; tampered, lower-seq, expired, wrong-key and symlink archives all rejected; existing suites unchanged (`sim/test_remote_approvals.py`, `Tests/AgentAppTests/ManagedRemoteControlTests.swift`) |
| 1. Pipeline + hosting | Offline roots, release key, `build-bundle` / `sign` / `publish` / `republish` scripts; static host; publish bundle = today's `Resources/` content | Re-download verifies; host serving a modified blob or old index is detected; publishing does not need the roots |
| 2. Baseline + trusted bootstrap | Apps embed signed baseline and bootstrap package/digest; compiled code exports it; operator verifies and installs updater/dependencies/pins outside model turns (§3.5) | Altered updater or pin package fails the independent hash check before execution; bot account cannot replace trusted files or lower the floor checkpoint; offline first launch works |
| 3. Box updater | Enable the updater installed in step 2: timer and channel pull on boxes (local and remote); status via advertised version | Linux and Mac box behind NAT update with outbound only; host down → no change; bad signature → last good; lowered state floor stops at the checkpoint; job running → deferred; plugin change → `reload_pending` |
| 4. Mac fetch + staged install | After steps 2–3, Mac forwards opaque box archives and signed metadata; management turn stages bytes and invokes the step-2 updater's `apply --staged` | Altered archive → trusted updater refuses apply, last good kept; Mac never executes scripts; box render matches today's output for all four skills; skills update without an app release |
| 5. Device-signed managed approvals (required) | Mac client migrates v1 → device-signed; iOS gains managed approvals, device-signed only (new compiled feature); box verifier; local device enrollment/revocation; box nonces; explicit v1 → device-required cutover (§4). Separate approval keys/state from release keys/updater | Local and remote boxes accept valid device decisions with update host offline; reject tampering, replay, wrong box/profile, revoked keys and shared-key-only downgrade after enrollment; Mac v1 still works before cutover; iOS has no shared-key code path and offers managed approvals only on device-required boxes; native Hermes path unchanged |
| 6. Config + flags | Policy defaults, prompts, copy and flags read from bundle with compiled fallback, Mac + iOS | Remove key → compiled default; wrong type → default plus logged reason; kill switch works |
| 7. SDUI v1 | Catalogue renderer on Mac + iOS; first cards and forms from bundles | Golden snapshots both platforms; unknown component → fallback; `critical` → "update required"; documents cannot reach review or secret screens |
| 8. Channels in use | Canary/beta/stable, percent rollout, local pin, rollback drill, release-key rotation drill | Drill: bad bundle on canary → republish roll-forward → all canary consumers recover without a build |

## 9. Cost (estimates only, nothing provisioned)

Load **[A]**: tens of boxes and hundreds of app installs, each polling a ~2 KB index every 6 h, so about 1–2k requests/day. Bundles are about 0.5–2 MB, with a few releases a month. That is well under 10 GB/month of egress.

| Option | Shape | Est. monthly (EUR, unverified list prices) |
| --- | --- | --- |
| A. GitHub Releases | Same place as the appcast; one release per bundle + an index asset | €0 (custom domain not possible; index URL tied to the repo) |
| B. Object store + CDN | Cloudflare R2 or Backblaze B2 behind a CDN on `updates.<domain>` | €0–5 (free tiers likely cover it; R2 has no egress fee) |
| C. Small VPS | nginx serving static files, Hetzner-class | ~€5 + ops time |

Other costs: two hardware keys for the roots and release key (~€100–150 one-off **[A]**); domain (~€15/yr, possibly already owned); CI on free tiers; the Apple Developer Program is already needed for iOS. No on-call duty: an outage only delays updates. **Recommend B**, with A kept as a mirror, because the signed indexes work on any host.

## 10. Decisions for Konrad

1. **Key custody.** (a) One release key on the Mac, like Sparkle today. (b) Two offline root keys (hardware, stored apart) that sign a key manifest delegating to one release key on a hardware token. (c) (b) plus a second signer per release.
   **Recommend (b).** A stolen laptop key then costs a key-manifest rotation, not an app rebuild and box re-pin. (c) adds little for a single publisher. Keep the bundle keys separate from the Sparkle `SUPublicEDKey`.
2. **How boxes apply bundles that contain code.** (a) Auto-apply everything on the subscribed channel. (b) Auto-apply data components (settings/config, prompts, copy, flags, UI definitions), even when they ship alongside code; code components (box tools, skill scripts) download and verify but wait for one local confirmation in the Mac app per box (or `swarmhub-update apply` on the box). (c) Everything manual.
   **Recommend (b).** Code that runs on remote boxes then needs both Konrad's signature and a local yes, which caps the blast radius of a release-key compromise. Prompt and config fixes still flow on their own. Revisit (a) for `canary` boxes.

## Decision (Oct 20, 2026)

Konrad approved plan B (this document) with every recommendation. This supersedes plan A (`CORE-PLAN-A-central.md`); `COMPARE.md` records the comparison.

1. **Key custody: §10 decision 1(b).** Two offline recovery (root) keys on hardware, stored apart, sign the key manifest (1-of-2 threshold, §2.1). They delegate to one publishing (release) key on a hardware token. The bundle keys stay separate from Sparkle's `SUPublicEDKey`.
2. **Apply policy: §10 decision 2(b), per component** (Konrad: "settings/UI auto-apply, box code needs per-box local confirm").
   - **Data components** (settings/config, prompts, copy, flags, UI definitions; class `data`, §2.3) auto-apply on the subscribed channel, also when the same bundle carries code.
   - **Code components** (box tools, skill scripts; class `code`) download and verify, then wait in `pending_confirm` for one local confirmation per box, given either in the Mac app or with `swarmhub-update apply` on the box. One confirmation covers the code components of one bundle version on one box.
   - **Dependency rule.** A data component that declares `requires_component` on a code component, directly or through other components, at a version the box has not applied yet waits in `pending_confirm` too. It applies together with that code once the box confirms, and not before. If the confirmation never comes, it stays pending until a later bundle no longer needs that code. Dependencies count only when declared in the signed manifest; a data component without one applies against the code already on the box, so the release tooling must declare it whenever new data needs new code.
   - **Rollout.** Every release goes to the canary group first, then beta, then stable (§2.2). Canary boxes also need the local confirmation for code. Auto-applying code on canary ("revisit (a)") is not part of this decision.
3. **Hosting: §9 option B.** Static object storage behind a CDN on `updates.<domain>`, with GitHub Releases (option A) as the backup mirror. Nothing is provisioned yet.
4. **Hermes is never altered.** No phase modifies a Hermes file, binary, configuration or service, and the updater never restarts Hermes (§3.4).

The implementation order is in `CORE-PHASES.md`. Steps that need Konrad (production deploys, money, real keys and secrets, App Store submission) are marked there.

## Assumptions and open items

- Boxes can run a user-level timer (systemd `--user` or launchd) under the bot's account. I did not inspect installed Hermes, skill or proxy versions on real boxes, or how to read the Hermes version.
- Atomic directory replacement under `skills/swarmhub/` does not disturb Hermes skill loading mid-turn **[A]**. This needs to be checked on a real box in step 3.
- App Store wording, CDN prices and hardware-key choice should be checked before building or buying.
- This plan comes from reading the source. It is not proof that anything works. No code was changed, and nothing was run or provisioned.
