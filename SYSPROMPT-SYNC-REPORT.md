# Bot prompt sync follow-up, 2026-10-20

Branch `swarmhub/sysprompt1`, follow-up to `e65ba5b` and the sysprompt6 review.

## Current review follow-up

- iOS now keeps load failures in `botPromptSyncWarning`, independent of transient status `notice`.
  A non-blocking root banner appears across welcome, chats and other tabs. Dismiss clears only the
  warning; Retry loading preserves unreadable files and clears the warning on successful local load,
  invalidating cached clients so recovered prompts take effect. No transport or Mac settings write-back.
- Added iOS Swift tests (2 functions / 3 cases) for corrupt/future-schema warnings surviving status
  changes, failed retry, dismissal, preserved bytes, and successful recovery. Wired a hosted
  `SwarmHubTests` target into the generated project and shared scheme; test storage uses isolated paths.
- Core persistence accepts an injectable writer with the existing atomic writer as its default.
  Core and Mac failed-save tests now inject a throwing writer, verify it was called, and verify
  unchanged memory and saved bytes. They no longer depend on directory replacement behavior.
- Ran `PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest sim.test_prompt_sync -v`:
  **9 tests passed, 0 failures, 0 skips** (0.687s), including all 19 vectors. A search of sim sources
  found no other suite touching this code. Historical full-suite results are retained below.
- Project regeneration was byte-for-byte deterministic; scheme XML parsed with the test target present.
  `git diff --check` passed. All 10 changed/new files are below 500 lines (maximum 305).
  Hermes is untouched. Commit unavailable: `git add` could not create the worktree's `index.lock`
  on a read-only filesystem; changes remain unstaged on `swarmhub/sysprompt1` at `e65ba5b`.
- **Swift tests and native UI remain unbuilt/unrun**: no Swift/Xcode toolchain here, including the new
  iOS target. Banner layout, accessibility and Apple data protection still require native verification.

## Mechanism finding

There is still **no concrete Mac/iOS transport** for settings or prompt slots. Local persistence,
the shared document, and `BotPromptSyncTransport` provide the integration points; neither app can
automatically deliver a document to the other. No iCloud KVS, CloudKit, App Group, pairing, QR code,
or export/import carrier is wired. Shared Hermes sessions and transcripts do not carry these settings.

The original references still apply: `Apps/iOS/README.md` says roster bindings, reactions and
preferences are not synchronized; `docs/ios/specsheet.md` requires separate shared metadata for
cross-device preferences and assumes stock Hermes. The core plan's release-signed update service
is one-way configuration delivery, not a carrier for per-user edits. Hermes remains untouched.

## Changes

- Swift timestamp increments saturate at `Int64.max` instead of overflowing. Python uses the same
  ceiling and rejects stamps outside Swift's representable nonnegative range. At saturation a later
  edit is safe, but cannot advance the timestamp: the existing origin/value byte tie-break decides
  conflicts. Four new shared scenarios cover reaching the ceiling, directly receiving it, repeated
  edits (text and rule lists), and delayed delivery at the ceiling.
- Split the old 1,260-line fixture into `Tests/Fixtures/prompt_sync/index.json` and six scenario files.
  Both Swift and Python load the manifest. All 15 original scenarios remain, for 19 total; every
  fixture file is below 500 lines. Python checks the file limit.
- Added `BotPromptSyncStore` in SwarmHubCore. It saves the full `BotPromptSyncState` (including the
  Mac's last observations) and a stable device origin in atomic local JSON writes. Failed saves do
  not advance memory. Corrupt/future-schema files throw and remain untouched. Loaded fields undergo
  merge validation. Byte-based JSON comparison preserves Unicode-only changes Swift considers equal.
- Mac loads `bot-prompt-sync.json` beside `store.json`, observes local settings before rendering a
  Hermes bot's default prompt, and renders merged slots. Demo stores use memory only. Mac settings
  and custom personas are never rewritten. OpenClaw and Mac-only connection addresses/profiles that
  mobile cannot represent retain their existing local rendering behavior.
- iOS loads `SwarmHub/bot-prompt-sync.json` from Application Support, renders saved slots when creating
  clients, and exposes explicit-edit and sync methods. It never publishes mobile defaults. Edits or
  merges invalidate cached clients so subsequent turns use the saved context. No edit UI was added.
- Added `BotPromptSyncTransport.exchange`, plus callable sync entry points on both apps. Exchanges
  carry only `BotPromptDocument`, never local observation history. Responses merge into the latest
  state after the await so concurrent local edits survive. Carrier implementations must preserve
  remote fields when publishing. No concrete carrier, entitlements, network calls or Hermes changes.
- Review follow-up: a Mac sync load or observation-save error now renders local settings and leaves
  chat/backend creation working. A dismissible inline warning reports the fallback and preserved file
  without opening a backend-error alert or entering the fatal error channel;
  failed saves still leave sync memory unchanged. iOS client creation likewise uses local defaults
  after a sync load failure and shows the dedicated root warning. No corrupt file is reset or replaced.
- Mac sync identity now uses the same HTTPS-only `ConnectionAddress` policy as mobile. HTTP endpoints,
  including the default Mac URL and IPv4/IPv6/localhost loopback, render locally without publishing
  sync entries. The demo persistence test uses HTTPS so it still exercises an actual observation.
- Swift fixture loading now uses typed `Decodable` models directly from JSON bytes. Both operation
  timestamps and received stamp timestamps decode as `Int64`, with explicit checks for `Int64.max`
  and `Int64.max - 1`; there is no NSNumber/Double conversion on the vector path.

## Prior sysprompt6 validation (historical)

- Focused Python command: `python3 -B -m unittest sim.test_prompt_sync -v`.
  **9 tests passed**, including all 19 shared scenarios, 300 randomized three-device convergence
  trials, merge-law checks, fixture sizes and scalar/rule limits.
- Full offline command: `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`.
  **446 tests run, 23 failures, 13 skips** (380.487s). Eight failures are sandbox permission/namespace
  expectations in `test_fixes6`, `test_fixes7`, and `test_fixes8`. All eight reproduce on an unchanged
  `19fa540` snapshot: 5 selected test methods, 8 failures including subtests (2.180s). The other 15
  failures in `test_macsmoke2`/`test_macsmoke_library` are all assertions about unexpected global
  `/tmp/code-job.*` or `/tmp/macsmoke1-*` entries. Their tests and harness are unchanged from HEAD;
  smoke cleanliness remains unverified. The focused prompt-sync tests also pass within the full run.
  Raw logs: `/tmp/sysprompt-review-sim.log`, `/tmp/sysprompt-review-baseline.log`.
- Swift coverage written (not run): `BotPromptSyncIntegrationTests.swift` has 5 functions / 10 cases,
  including corrupt and future-schema file fallback, successful backend creation, a failed observation
  save with unchanged memory/disk, and default/localhost/IPv4/IPv6/remote HTTP addresses. The demo
  test still performs a sync observation. `BotPromptSyncTests.swift` has 5 functions, including all
  19 vectors and explicit exact-integer ceiling checks. The 10 persistence/transport tests remain.
- `git diff --check` passes. All 7 changed files are under 500 lines (maximum 357).
- **Swift is unbuilt and unrun**: this host has no Swift toolchain. Neither native app, the inline warning presentation, nor Apple
  filesystem/data-protection behavior was verified here. Build/test the core and Mac targets on
  macOS, and build the iOS target with Xcode before release.
- Commit unavailable: `git add` failed creating the worktree's `index.lock` with "Read-only file
  system". All changes remain unstaged in this worktree; the branch is unchanged.

## Open questions for the owner

1. **Transport:** choose iCloud key-value storage (`NSUbiquitousKeyValueStore`) versus manual
   export/import. iCloud would require matching entitlements and provisioning for both apps;
   Developer ID/account support is unverified. Export/import would require an explicit file or QR
   handoff. This remains the owner's decision; no transport has been selected or implemented.
2. **Mac settings semantics:** a winning mobile edit changes the rendered prompt while the Mac's
   source settings can still show their local values. Whether a future design writes back eligible
   fields or limits mobile edits to fields the Mac does not derive remains an owner question.
   This change adds no write-back into Mac settings or personas.
3. **iOS editing:** there is still no slot editor. The explicit-edit API is available for future UI;
   mobile defaults are never published. UI scope and behavior remain undecided.
