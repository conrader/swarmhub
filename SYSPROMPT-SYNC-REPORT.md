# Bot prompt sync follow-up, 2026-10-20

Branch `swarmhub/sysprompt1`, follow-up to `780653c` and the sysprompt4 review.

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

## Validation

- Focused Python command: `python3 -B -m unittest sim.test_prompt_sync -v`.
  **9 tests passed**, including all 19 shared scenarios, 300 randomized three-device convergence
  trials, merge-law checks, fixture sizes and scalar/rule limits.
- Full offline command: `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`.
  **446 tests run, 11 failures, 13 skips** (403.783s). Eight failures are sandbox permission/namespace
  expectations in `test_fixes6`, `test_fixes7`, and `test_fixes8`. All eight reproduce on an unchanged
  `780653c` snapshot: 5 selected test methods, 8 failures including subtests. Three other failures in
  `test_macsmoke2`/`test_macsmoke_library` report unexpected global `/tmp/code-job.*` and
  `/tmp/macsmoke1-*` entries. Targeted rerun: **3 tests, 3 failures**, again on global temporary
  directory checks. Their tests and harness are byte-identical to `780653c`; a clean smoke result
  remains unverified while this interference continues. Raw logs:
  `/tmp/sysprompt1-sim-tests.log`, `/tmp/sysprompt1-baseline-tests.log`.
  Smoke rerun: `/tmp/sysprompt1-smoke-rerun.log`; focused sync: `/tmp/sysprompt1-prompt-tests.log`.
- Swift tests added: 10 persistence/transport tests in `BotPromptSyncStoreTests.swift` and 4 Mac
  integration tests in `BotPromptSyncIntegrationTests.swift`. The existing shared-vector Swift
  tests now read the split fixtures and check rule-list values as well as text.
- **Swift is unbuilt and unrun**: this host has no Swift toolchain. Neither native app nor Apple
  filesystem/data-protection behavior was verified here. Build/test the core and Mac targets on
  macOS, and build the iOS target with Xcode before release.
- Commit unavailable: `git add` failed creating the worktree's `index.lock` with "Read-only file
  system". All changes remain unstaged in this worktree; the branch is unchanged.

## Remaining owner decision

Choose the concrete carrier (iCloud key-value storage versus export/import) and any future mobile
edit UI. No automatic cross-device delivery is claimed until a carrier is implemented and wired.
