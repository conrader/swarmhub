# AgentApp review: Grok Bot-style parity pass (stated as commit 977acb0)

**Verdict: FAIL.** One normal user flow silently destroys the user's saved chats. Two other paths very likely crash the app. Several README parity rows say "Done" for UI that does nothing. The asset provenance check passes. Most fixes are small; see "Minimum to reach PASS-WITH-ISSUES" at the end.

## Scope and limits (what was and wasn't verified)

- **Read-only code review** of all 965 lines (`Sources/`, `Tests/`, `Package.swift`, `scripts/`, `README.md`, the briefs), plus a visual check of `Resources/Avatars/*.png` and `docs/*.png`.
- **Not built, not run.** The review host is Linux with no Xcode or SwiftUI. Every finding comes from reading the code. Findings that depend on macOS framework behaviour are marked *(likely; macOS behaviour, not reproduced)*.
- **Commit not confirmed.** The review directory is not a git checkout, so I could not check that these files match `977acb0`.
- The README's Hermes API claims (endpoint, `/health`, `hermes.tool.progress`) were **not** re-checked against Hermes docs. The README was compared with the code, not with the real Grok Bot app.

---

## HIGH

### H1. Launching the app overwrites the user's saved bots and chats with demo data
`Stores/AppStore.swift:18-19`, `:39`; `AgentApp.swift:10`

```swift
if let data = ..., let decoded = try? JSONDecoder().decode([Bot].self, from: data) { bots = decoded }
if bots.count < 4 { loadDemoData() }   // loadDemoData() ends with save()
```
- **Normal flow:** a fresh install starts with 5 demo bots. The user deletes 2, then quits and relaunches. Because `bots.count < 4`, the demo data replaces their bots and `save()` writes it to `store.json`. The real conversation history is gone. There is no backup and no warning.
- **Decode failure:** any decode error (a corrupt file, or a future required key) is swallowed by `try?`, leaves `bots = []`, and leads to the same overwrite.
- **README screenshot command:** running it on a real user's machine with `AGENTAPP_SNAPSHOT=...` calls `loadDemoData()`, which overwrites the real `store.json` (`AgentApp.swift:10`). `AGENTAPP_APPEARANCE` also permanently rewrites the user's theme preference (`AgentApp.swift:8`).
- **Fix:** seed demo data only when the file does not exist. On a decode failure, move the file aside (`store.json.corrupt-<ts>`) and never write over it. Keep demo/snapshot data in memory only (no `save()`).

### H2. A reply finishing while the app is in the background probably crashes it *(likely; macOS behaviour, not reproduced)*
`Stores/AppStore.swift:68-72`, `Views/SettingsView.swift:23`

- The app is built and run as a bare SwiftPM executable (`scripts/run.sh` runs `.build/debug/AgentApp`), not as a `.app` bundle. `UNUserNotificationCenter.current()` raises `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") when the process has no bundle.
- **Trigger:** both notification settings default to on. The user sends a message, switches to another app, and the stream completes. `notifyIfNeeded` then runs and the app likely crashes. Turning the Settings → Notifications toggle off and back on hits the same call.
- **Separate bug even inside a bundle:** authorization is requested only in the toggle's `onChange`, which never fires for the default value. On a fresh install notifications are therefore never authorized and never appear.
- **Fix:** guard on `Bundle.main.bundleIdentifier != nil`. Request authorization at first launch. Skip notifications for empty, cancelled or errored replies.

### H3. Clearing the Hermes Base URL field makes the next Hermes message crash the app
`Stores/AppStore.swift:81`

`URL(string: UserDefaults…"hermesBaseURL" ?? default)!` uses a value that `@AppStorage` writes on every keystroke. If the user empties the field (`URL(string: "")` returns nil), the next send to a Hermes bot force-unwraps nil and crashes. `SettingsView.testHermes` handles the same value safely with `??`, so the two paths are inconsistent.
- **Fix:** if the URL fails to parse, surface `BackendError.invalidURL` instead of force-unwrapping.

### H4. There is no Stop button, and pressing Enter during a stream starts a second stream
`Stores/AppStore.swift:48-53`, `:73`; `Views/ComposerView.swift:11-13`

- Nothing in the UI calls `AppStore.stop()`. BRIEF.md required a stop button, and the README claims "cancellation" is Done. In practice the user cannot stop a runaway agent stream.
- The send **button** is disabled while streaming, but the **Enter** handler (`onKeyPress(.return)`) calls `send()` unconditionally, and neither `ChatView.send` nor `AppStore.send` checks `isStreaming`. The second call replaces `streamTask` without cancelling the first, so two streams write at once. Whichever stream ends first sets `isStreaming = false` while the other is still running.
- `stop()` cancels the backend for `selectedBot`, which is not necessarily the bot that is streaming.
- **Fix:** add a Stop control that replaces Send while streaming. Guard `send` on `isStreaming`. Remember which bot is streaming.

---

## MEDIUM

### M1. A demo approval and demo routines are added to real user data on every launch, and approvals go to the wrong bot
`Stores/AppStore.swift:19`, `:41-44`, `:74-78`; `Views/ChatView.swift:19`

- `loadDemoActivity()` runs unconditionally in `init`. Every launch adds the fake approval "Atlas wants to publish the reviewed release notes…" and attaches the demo routines to the user's first bot.
- `approvals` is a single global list. It is rendered after message index 1 (near the **top**) of **every** bot's chat. So an approval raised by a new Mock reply appears far up a long chat where the user won't see it, and bot A's approval also shows in bot B's chat.
- `decide()` writes "Approved: …" into `selectedBot`, which may be the wrong bot. It reports the approval even when the backend rejects it: Hermes `resolveApproval` throws, and the `try?` swallows it. That system message then becomes part of the history sent to Hermes on the next request.
- **Fix:** keep approvals per bot and per message, persist them, and show the result the backend actually returned. Drop demo activity unless in demo mode.

### M2. The draft-email card's "Send" shows "Email sent" without sending anything
`Views/MessageView.swift:100`

`Button("Send") { sent = true }` only flips local view state, and the title changes to "Email sent". This misleads the user about an outbound action. The state is not persisted either: a lazy row that scrolls away can reset it, so the card shows Send again.
- **Fix:** disable the button or label it as a stub until a backend action exists.

### M3. The README parity checklist overstates what is done
Row by row against the code:

| README row | Claim | Actual |
|---|---|---|
| Core chat | Done, incl. cancellation | No Stop UI (H4). Markdown is hand-rolled: only `## `, paragraphs that start with `- `, and fenced code. `#`/`###`, numbered lists, quotes and tables render raw. The copy icon on code blocks is decorative. |
| Inline content | Done | Every card is visual only, and nothing creates them except demo data: no backend emits these presentation types (Hermes only yields text tokens). The `Send` button fakes a send (M2). Option buttons only highlight locally and send nothing (`MessageView.swift:119`). Link pills have no URL and an empty action (`:46`). The voice memo play button toggles an icon with no audio (`:45`). The image card is a placeholder (`:47`). **Should be "Stubbed".** |
| Composer | Done; "upload adapter-dependent" | Attaching a file only appends the text `[Attachment: name]` (`ComposerView.swift:16`). No adapter uploads files. There is no mic button (BRIEF-visual asked for one). **Stubbed.** |
| Notifications | Done | Never authorized by default, and likely crashes (H2). |
| Replies and tapbacks | Done, "persisted" | Adding a reaction does not call `save()` (`MessageView.swift:16`), so it is only persisted if some later action saves. The reply link is display-only: it is not threaded and not sent to the backend. Reactions cannot be removed. |
| Computer | Done, "take-over entry point" | "Take over" and "Open" open the same sheet (`InfoPanel.swift:48`). The 220-pt preview is already a fully interactive `WKWebView`, so there is no view-only or take-over distinction, and opening the sheet creates a second live VNC session. **Partial.** |
| Media | Done | Grid of SF Symbol placeholders. No thumbnails and nothing opens. **Partial.** |
| Settings | Done / stubbed | The Accent picker is stored but never read; the app hard-codes `.tint(.primary)` (`ContentView.swift:16`). Usage shows a fixed "128 messages". Updates always says "You're up to date", and Check for Updates does nothing (`SettingsView.swift:32-34`). |
| Quick switcher | Done, "opens Settings" | Uses a private selector, `showSettingsWindow:` (`ContentView.swift:37`). *(Likely; macOS behaviour, not reproduced)* on macOS 14+ this logs "Please use SettingsLink" and does nothing. There is also no arrow-key or Enter selection. |
| Bot sidebar | Done, "groups" | Two fixed labels ("MY BOTS", "WORKSPACE"). There are no user or section groups. |
| Original bot faces | Done, 12 faces | 12 recolours of one identical shape (`DesignSystem.swift:40-50`), not 12 geometric heads. Clay avatars may render blank under `swift build` (M5). |
| Hermes | Partial, "progress parsing works" | The parser emits `.status`, but `AppStore` drops it (`case .status, .subAgent: break`, `AppStore.swift:59`), so progress is never shown. |
| *(missing)* | — | The sub-agents panel from BRIEF.md and BRIEF-visual.md was removed. `.subAgent` events are dropped and no UI shows them. The README architecture section still lists "sub-agent … types". This is a regression the table doesn't mention. |

Accurate rows: three-column layout, Overview, Routines (Stubbed, though see M1; routines also aren't persisted and can't be edited), Members (Stubbed), OpenClaw (Stubbed). The performance section is honest that it measures only state initialization (it exits before the first frame).

### M4. Every streamed token re-renders the whole window
`Stores/AppStore.swift:58`, `:47`; `Views/ChatView.swift:17`, `:24`; `Views/DesignSystem.swift:56-63`; `Views/InfoPanel.swift:45-46`

- Each token runs `assistant.content += token; objectWillChange.send()` on the **store**. That invalidates every view holding the `@EnvironmentObject`: ContentView, Sidebar, ChatView and InfoPanel. `MessageView` already observes `message.content`, so the store-level send is redundant.
- On each of those passes:
  - ChatView rebuilds `Array(bot.messages.enumerated())`, which is O(n), and scrolls.
  - InfoPanel's Media tab filters all messages twice.
  - In the direct-`swiftc` build (the one the README says was verified), every clay avatar is re-read from disk with `NSImage(contentsOf:)` on each render. There is no cache.
- `save()` JSON-encodes all bots and every message synchronously on the main thread. It runs at the start and end of each stream and on every sidebar toggle, so a 5k-message history will stall the UI. The README partly acknowledges this.
- **Fix:** drop the per-token store notification (scroll on a throttled signal instead). Cache images. Save debounced, off the main actor.

### M5. Clay avatars probably render blank in `swift build` builds *(likely; macOS behaviour, not reproduced)*
`Package.swift:14`, `Views/DesignSystem.swift:11`

`.copy("Resources/Avatars")` puts the files under an `Avatars/` subfolder in the resource bundle. `Image(name, bundle: .module)` looks names up at the bundle's top level and does not search subfolders. The fallback build's loader (`AvatarAssets`) uses explicit paths, which is likely why this went unnoticed. That loader also depends on the cwd or `argv[0]` and silently falls back to an empty image.
- **Fix:** use `.process("Resources/Avatars")` or an asset catalog, or load with `Bundle.module.url(forResource:withExtension:subdirectory:"Avatars")`.

### M6. Credential and network handling
- `HermesBackend.swift:14`, `:51`: the Bearer key is sent to any configured URL, including plain `http://` on a remote host. Nothing enforces HTTPS outside loopback.
- `KeychainStore.swift:8-11`:
  - It deletes the item and then adds it, ignoring both `OSStatus` results. If the add fails, the key is silently lost.
  - It writes to the Keychain on **every keystroke** of the SecureField (`SettingsView.swift:26`), and again from `onAppear`.
  - It uses the legacy file keychain without `kSecUseDataProtectionKeychain`. With an unsigned or ad-hoc binary, every rebuild re-prompts for Keychain access.
  - Prefer `SecItemUpdate`, falling back to add; check the status; save on commit, not per keystroke.
- `SettingsView.swift:9`: the noVNC URL is stored in UserDefaults in plaintext. noVNC URLs commonly carry `?password=…`, so this belongs in the Keychain or should strip the password.
- Positives: no secrets in the repo or the JSON store, and the API key is not logged.

### M7. Hermes streaming edge cases
`HermesBackend.swift:23-39`
- `URLSession.shared` uses a 60 s idle timeout. A tool call that runs longer without emitting progress will abort the stream.
- Error JSON sent mid-stream is ignored, which leaves an empty assistant message.
- Non-2xx responses discard the body, so the user only sees "Hermes rejected the request".
- Multi-line SSE `data:` fields are parsed one line at a time.
- Every request sends the entire conversation, including demo-card text ("Draft ready", "Voice note") and `system` "Approved:" lines. The history is unbounded.

---

## LOW

- **New-agent sheet drops fields.** For new bots it ignores Title, Description, "Show in sidebar" and Notifications: `addBot` only takes name, persona, backend and avatar (`AppStore.swift:45`, `BotEditorView.swift:20`).
- **Conflicting ⌘N.** "New Agent" is bound to ⌘N alongside the WindowGroup's default New Window ⌘N (`AgentApp.swift:22`). With multiple windows, the global `showingNewBot`/palette flags also open sheets in every window.
- **Unread reset not saved.** Clearing `unreadCount` on selection doesn't save (`SidebarView.swift:36`).
- **State leaks across bots.** The composer draft (`ChatView` `@State`, not keyed by bot) and `replyTo` (global) carry over when switching bots. The reply ID then points to a message in another bot.
- **Routine rows go stale.** `RoutineRow` copies `routine` into `@State` once, so it won't reflect store updates (`InfoPanel.swift:58`).
- **Hardcoded personal data and placeholder figures.**
  - "Konrad" appears in the sidebar account button, Settings › Account, Members and the demo email signature.
  - The demo recipient `maya@northstar.co` may be a real domain; use `example.com`.
- **Tests are trivial.** There are two (enum count, URL suffix). Nothing covers persistence or migration (H1 would have been caught), the SSE parser, URL building, or the Keychain.
- **Hard-to-read code.** Dense one-line style, e.g. `MessageView.swift:45` is ~650 chars on one line and `SettingsView.swift:5` packs a whole enum onto one line. This hurts reviewability more than the ≤500-line file limit helps.
- **Fragile fallback build.** It hard-codes `/Applications/Xcode-16.2.0.app` and `arm64`, and word-splits `$(find …)`, so paths with spaces break.

---

## Third-party asset provenance: PASS (with one caveat)

- **No Grok or xAI references.** No source file mentions Grok or xAI; the only mentions are in the briefs and the README disclaimer. I found no copied UI strings, prompt text, fonts or icon files. All icons are SF Symbols, and the tapback set is plain Unicode emoji.
- **Flat faces are original.** The 12 faces are drawn procedurally with `Canvas` (rounded rect, antenna, two dots and a curve). There is no raster artwork. They are generic and not traceable to any third party.
- **Caveat: clay PNGs have no provenance record.** The 9 PNGs (`Resources/Avatars`, ~210 px, 30–46 KB) carry no embedded metadata (no tEXt/iTXt/eXIf/C2PA). They look like generic 3D-clay renders, probably AI-generated. They predate this pass, which kept them as an alternative set. I found nothing tying them to Grok Bot, but nothing in the repo records where they came from. Add a short `Resources/Avatars/PROVENANCE.md` (generator or tool, date, licence) before shipping.
- **Screenshots** in `docs/` are renders of this app.

---

## Minimum to reach PASS-WITH-ISSUES

1. H1: never overwrite an existing `store.json`, and keep demo/snapshot data out of real storage.
2. H2/H3: guard the notification centre on a bundle identifier, and stop force-unwrapping the configured URL.
3. H4: add a Stop button and block concurrent sends.
4. M1/M2: stop seeding demo activity into real data, and make the fake "Send" clearly a stub.
5. M3: correct the README parity table (Inline content, Composer, Notifications, Computer, Media, Accent → Stubbed/Partial; mention the removed sub-agents panel).
6. Build with `swift build` and confirm the clay avatars render (M5). Neither has been checked.
