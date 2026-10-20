# Bot prompt slot sync (Mac ↔ iOS), 2026-10-20

Branch `swarmhub/sysprompt1`, base e67ede0.

## Mechanism finding

The brief said to reuse "the app's existing settings/sync mechanism". **This branch has no Mac↔iOS settings sync.**
- `Apps/iOS/README.md`: "roster bindings, reactions and preferences are not yet synchronized between clients".
- `docs/ios/specsheet.md` §Sync and §Contract: cross-device preferences "require a separate shared metadata
  service"; Hermes stays stock with no custom routes ("not assumed Hermes APIs").
- What the two apps do share is the Hermes server's sessions and transcripts. They share nothing else: no iCloud,
  CloudKit, App Group, pairing, QR code or export/import path in `Sources/` or `Apps/iOS/`.
- The core plan's update service (CORE-PHASES P6b, on another branch) carries release-signed config one way. It is
  not a carrier for per-user edits.

## What landed (transport-independent)

- `Packages/SwarmHubCore/Sources/SwarmHubCore/Configuration/BotPromptSync.swift`: every `BotPromptContext` slot
  (name, role, owner, coordinator, timeZone, language, approvalRules, quietHours) has its own stamp
  `{value, at (ms), origin}`.
  - **Last write wins per field.** A tie on `at` goes to the higher origin bytes, then the higher value bytes, so the
    merge is a total order: commutative, associative and idempotent.
  - **Hybrid clock.** A local edit is stamped `max(now, seen + 1)`, so an edit made after seeing a value wins even
    on a slow clock.
  - **Mac `observe`.** The Mac's slots are derived from other settings (identity, coordinator, routing, quiet hours).
    `observe` publishes only the fields that changed since the last render. The first reading is a time-0 baseline
    that only fills empty fields.
  - **iOS `edit`.** An explicit UI edit stamps only the fields it changes. iOS defaults are never published.
  - **Empty coordinator.** `coordinator ""` means "no coordinator", so clearing it syncs too.
  - **Rejected values.** Oversized values (over 2000 scalars, over 50 rules) and negative times are dropped. A
    document with a different schema is not merged.
  - **Personas untouched.** The document has no persona field, and unknown keys are ignored.
  - **Bot key.** `botKey(ConnectionAddress)` is the normalized server URL (lowercased host) plus `#profile`.
    Both apps can derive it.
  - **Byte comparison.** Comparisons use UTF-8 bytes, not Swift `String ==`, so NFC and NFD spellings stay
    distinct, matching the Python port. A document missing `schema` or `bots` merges nothing instead of failing to
    decode. Both gaps were found by an independent static review and now have vectors.
- `Tests/Fixtures/prompt_sync_vectors.json`: 15 scenarios plus bot-key cases. The Python and Swift tests both read
  this file.
- `sim/prompt_sync.py` and `sim/test_prompt_sync.py`: a Python port with the vectors, 300 randomized 3-device
  convergence trials with skewed clocks, and merge-law checks. The port reads field names and limits from the
  Swift source.
- `Packages/SwarmHubCore/Tests/SwarmHubCoreTests/BotPromptSyncTests.swift`: the vectors (sync goes through the JSON
  wire format), bot keys, persona preservation under `compose`, and the wire shape. Written but **not built**:
  there is no Swift toolchain on this host.

**Not wired yet:** neither app persists `BotPromptSyncState` or calls `observe`/`merge`. Wiring has to wait for
the transport decision below.

## Open questions for Konrad

1. **Transport.** No existing mechanism fits. My recommendation is iCloud key-value storage
   (`NSUbiquitousKeyValueStore`): Apple-hosted, no SwarmHub server, and the size fits. It needs the same
   `com.apple.developer.ubiquity-kvstore-identifier` on `com.konrad.agentapp` (Developer ID) and the iOS app. That
   means an Apple-portal capability and provisioning-profile change, which is Konrad's call. I have not verified
   Developer-ID support for KVS on this account. The alternatives are a manual export/import (QR or file), or a
   reserved stock Hermes session, which pollutes session lists and goes against the specsheet.
2. **Write-back on the Mac.** When an iOS edit wins (for example the owner), the Mac renders the synced value. The
   Mac's own setting (user name, routing-derived approval rules) is not rewritten, so the Mac settings UI can
   disagree with what the prompt uses. Should the Mac write synced values back where a matching setting exists, or
   should iOS edits be limited to slots the Mac does not derive?
3. **iOS edit UI.** The iOS app has no screen for these slots yet. Until one exists, iOS only receives values.
