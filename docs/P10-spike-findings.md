# P10.0 — Grok Bot import spike findings (go/no-go)

Status: **GO** (2026-10-13). Native, in-process full-history import works on Konrad's Mac. Every check passed except
the live Deny half of (d): Konrad clicked **Always Allow** in Run 1 and chose to keep it, so a live Deny can no
longer be shown. The Deny mapping is covered by the unit tests. No secret, token, machine id or message text is
recorded here.

## What was built
- `GrokProtocol`, `GrokKeychain`, `GrokSafeStorage`, `GrokSecretsFile`/`GrokCredentials`, `SecretBytes`,
  `GrokChecksum`, `GrokRequestHeaders`, `GrokProtobuf` (`Sources/AgentApp/GrokExport/`), all staying.
- The throwaway harness `--grok-spike <report.json>` (`Sources/AgentApp/GrokImport/HeadlessGrok.swift`,
  `HeadlessGrokLive.swift`).
- Pure tests over every vector (`GrokSpikeCryptoTests.swift`) and the main-actor isolation tests
  (`GrokSpikeIsolationTests.swift`). `swift test`: 160 green. Commits `d942015` and `2598b6c` on `p10`.

## The dialog (Run 1, as Konrad reported it)
- It named **Torvli**, the display name, not the `AgentApp` binary name.
- It **asked for the Mac login password**, the standard "wants to use your confidential information stored in
  'Grok Bot Safe Storage'" keychain dialog.
- Konrad clicked **Always Allow** (intended: Deny). The read succeeded after about 35 s of waiting on the dialog.
- No other dialog appeared: no folder-access or privacy prompt for `~/Library/Application Support/Grok Bot`.
- Konrad chose to keep Always Allow. Torvli builds signed with his Apple Development identity (team FQ5759XB2L)
  now read the item without prompting, and this survives rebuilds.

## Harness bug found and fixed in Run 1
The first live run hung after step (e). A stack sample showed the main thread waiting in
`HeadlessGrok.run(reportPath:)` on a `DispatchSemaphore`, while steps (f)/(g) ran in a `Task` that inherited
`@MainActor` from `AgentAppMain.init()`, so they could never start (a deadlock). `2598b6c` moved them into a
nonisolated `Task.detached` with its own URLSession queue. A regression test fails within 10 s when the old
isolation is restored.

## Go/no-go (Run 2, report `~/Library/Caches/Torvli-snapshots/grok-spike.json`, 0600, 20:19:03)
| Step | Result | Verdict |
|---|---|---|
| (a) attributes-only probe | osStatus 0, 7 ms, no dialog | ✅ |
| (b) cache | readable, 32 blobs, 17 roster rows, errno 0, 5 ms, no prompt | ✅ |
| (c) secrets file structure | 1 account, active account and machine id present | ✅ |
| (d) Keychain read | osStatus 0, 24 bytes, 9 ms (silent under Always Allow; Run 1 waited on the dialog for 35 s) | ✅ Allow; Deny waived (unit-tested) |
| (e) decrypt and shapes | token shape OK (3 segments), exp in about 56 days, machine id 36 chars, account binding `no-slot` (no slot blob, acceptable), team id not numeric (no team selected; must be optional in P10a) | ✅ |
| (f) live `ListGrokBotTranscriptEntries` (limit 2) | HTTP 200, 2 rows decoded, newest seq 28, body not gzip | ✅ |
| (g) honest `user-agent: Torvli/<version>` | HTTP 200 | ✅ accepted |

The spike exited on its own. Torvli had no files open under Grok Bot's folders, and the only files that changed
there were Grok Bot's own background status files. `networkProtocol` came back empty: URLSession task metrics
were not captured, which is informational only.

## Carry into P10a/P10c
1. **One Keychain read per import.** Steps (f)/(g) still read the Keychain a second time instead of reusing the key
   from (d). This is silent under Always Allow but would show a second prompt otherwise, which is a STOP trigger in
   a real import. Derive once and pass the key along.
2. **Team id is optional.** Konrad's account has no numeric team id. Treat "absent" as valid, not a shape failure.
3. **Honest user agent works.** Grok accepted `Torvli/<version>`. Per D1, changing the client headers needs
   Konrad's word; recommend identifying honestly.
4. Capture `URLSessionTaskMetrics` if `networkProtocol` matters, or drop the field.
