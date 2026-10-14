# SwarmHub technical reference

Detailed behavior, integration notes, and known limitations. For the overview and quick start, see the [README](../README.md).

SwarmHub is a desktop workspace for chatting with user-owned agent harnesses, targeting macOS, Windows, and Linux. This reference describes the current native macOS prototype; Windows and Linux versions are planned. There is no built-in model. The user-facing name is defined in `AppConstants.name` and mirrored by `CFBundleName`/`CFBundleDisplayName` in `Resources/Info.plist`, with tests keeping them consistent. The Swift package, module and executable keep the `AgentApp` codename; the bundle identifier, data folder and Keychain service remain stable so existing settings and keys carry over.

## Build and run

The current macOS implementation requires macOS 14+, Xcode 16.2, and Swift 6. Windows and Linux build instructions will follow their implementations.

```bash
./scripts/build.sh
./scripts/run.sh
```

### Install

```bash
./scripts/package-release.sh            # dist/SwarmHub.app + dist/SwarmHub-<sha>-arm64.zip, signed with the Apple Development identity
```

Quit the running app and back up any existing `~/Applications/SwarmHub.app` before copying `dist/SwarmHub.app` to `~/Applications/SwarmHub.app` with `ditto`. The data folder `~/Library/Application Support/AgentApp`, Keychain service `com.konrad.agentapp.backends`, and bundle id `com.konrad.agentapp` remain stable across updates. `SWARMHUB_SIGN_IDENTITY` selects a signing identity.

`scripts/build.sh` normally delegates to `swift build`. It also contains a direct Xcode 16.2 compiler fallback because the current host's `xcrun` crashes while loading `CoreDevice.framework`. The fallback verifies that the production target compiles, but it does not run SwiftPM tests.

`swift test` runs the whole suite on the MacBook (Swift Testing). On the older host where Xcode 16.2's `CoreDevice.framework` breaks `xcrun`, `build.sh` falls back to calling the compiler directly and tests cannot run there (logs under `docs/hermes-fix5-*.log`).

## Known issues

- Dirty release archives identify the base commit and dirty summary, but remain less reproducible than a clean committed build.
- Rules intentionally use first-match semantics; broad allow rules can shadow later deny/ask rules, so destructive ask/deny rules belong first.
- Reviewer-bot decisions have not been verified with a provider-backed real Hermes run; the throwaway gateway has no model provider credentials.
- Reviewer sessions are isolated per approval but are not deleted afterward: Hermes v0.21.7 session deletion support was not established from the checked API surface. Reviewer bots retain their configured tools, so reviewer mode should use a tightly restricted profile.
- Rule globs are textual rather than path-aware. Even with dangerous programs/options rejected, broad patterns such as `cat *` can cover multiple or parent-traversing paths; keep allow patterns narrow.
- The automatic-allow safety check has a deliberately short denylist rather than a complete model of every executable and option. Known residual reviewer/allow gaps include side effects hidden behind less common programs or options; keep custom allow patterns restricted to specific read-only commands. `rg --pre` and Git `--output` are blocked, but this is not a general sandbox.
- Reviewer-mode residuals include Git branch-mutating flags such as `--delete`, `-m`, and `--force`; an owner deny rule conservatively becomes a user prompt rather than an automatic denial.
- Reviewer Stop cannot capture a server run target before the first reviewer event; the fallback lookup can still race stream teardown. Reviewer timeout currently sends two stop requests to the same run.
- A reviewer run cancelled after streaming a decision can still count that decision as approval because Hermes cancellation currently maps to ordinary completion.
- Hermes v0.21.7 redacts approval commands with its general secret redactor before AgentApp sees them. That redactor can emit `***`, head/tail masks containing `...`, and `«redacted:…»` sentinels; AgentApp therefore refuses automatic approval for redacted-looking commands.
- Approval audit rows intentionally omit command text, show raw rule/reviewer UUIDs, and record Hermes' free-form action label. Some guard-driven audit reasons group different causes under shell-syntax or unsafe-operation wording and can therefore be misleading. The fixture harness routes approvals directly and its shell script relies on process exit status rather than grepping each expected line.
- Pending approvals cleared when a run ends are audited as denied/cancelled even though no final denial is posted to Hermes; delivery ambiguity after a lost automatic-decision response also remains.
- The unit suite still uses an injected backend for Mock reviewer routing and tests bot-setting persistence below the editor UI boundary; provider-backed and full UI reviewer flows remain unverified.
- The removed legacy `autoReview` preference may remain as a harmless stale UserDefaults key.
- Parser compatibility edges remain low-risk maintenance work; legacy package excludes also produce SwiftPM warnings.
- Display-only approval events remain visible but cannot be manually approved because Hermes did not provide the raw command that would execute.
- Keychain status reporting and per-keystroke writes, IPv6 loopback coverage, global streaming state, Hermes last-message-only sends, and some backend-specific wording remain limited.
- `swift test` may still be blocked on this Mac by Xcode 16.2's `_XPCTypeBool` toolchain break; the latest result is saved under `docs/approvals-fix4-*.log`.
- The live throwaway Hermes reached profile discovery but reported version `unknown (degraded)` and had no configured model provider (`docs/hermes-fix6-live-ermes.log`).

## Feature parity

This pass recreates the product structure and interaction patterns with original SwiftUI code, SF Symbols, and original assets, plus one vendored MIT library (BotAvatarsKit, see Credits) that draws the bot marks. It does not ship extracted artwork, fonts, icons, strings, or other assets from Grok Bot.

| Area | Status | Notes |
|---|---|---|
| Three-column layout | Done | Bot sidebar, centred chat, and an open-by-default right panel (Overview, Routines, Media, Computer, Members) that slides in and out like the sidebar; `Cmd+Shift+I` collapses it. Hidden title bar: the sidebar row and pane headers are the window's top edge and drag strips; `Ctrl+Cmd+S` (View → Toggle Sidebar) or the sidebar-row button hides the sidebar. Dark by default. |
| Bot sidebar | Done | Bot marks (still unless the bot is working or the row is hovered), unread dots, hidden bots, settings, and context actions (Mark as Unread — a manual flag kept in store.json that clears when the chat is opened — Hide, Mute, Delete). Sections are fixed (bots, groups), not user-defined folders. |
| Bot marks | Done | Each bot is a BotAvatarsKit mark in one of Grok's shapes and 11 colours: the stored Grok words, else derived from the bot's id with Grok's default-look rule (our own code). Gem, leaf, shield and cylinder are approximated (hexagon, drop, alien head, pill). Groups show a cluster of up to four member marks. Motion by context: list rows still unless working or hovered, the open bot's header/Overview and welcome views idle gently, a working bot hops; Settings → Appearance → Avatar motion (By context, Calm everywhere, Off); macOS Reduce Motion always wins. The 12 flat faces and nine clay PNGs remain as "Classic" in the editor. Bots imported before P15 get their mark at load (lazy, additive; `avatarName` untouched). No Grok artwork is shipped. |
| Core chat | Done | Text, user bubbles, Markdown/code (with Copy), streaming, Stop (local cancel plus Hermes `/v1/runs/{id}/stop`). **Steer:** while a turn streams and the server reports `run_steer`, Send posts to `POST /v1/runs/{run_id}/steer` and shows a dashed "Steered the running turn" bubble (a refusal marks it "Steer not delivered"); without `run_steer` only Stop is available while a turn runs. Markdown coverage is limited (`## ` headings, `- ` lists, inline styles, fenced code, images). |
| Replies and tapbacks | Done | Quote replies. **Reply in thread** forks the bot's session (`POST /api/sessions/{id}/fork` with `{"id": "agentapp_thread_<uuid>"}`) into a sub-conversation shown as "N replies"; the fork carries the whole transcript as it stood (Hermes has no fork-at-message). Hidden without `session_fork`. Tapbacks (👍 ❤️ 😂 ‼️ ?) are saved per message, local only. |
| Inline content | Done | Assistant Markdown becomes our own cards: question-with-options, draft (Send posts "Send it" to the bot; Copy), link pills for bare URLs, inline images (http(s) or `data:image/…`). See "Card syntax" below. |
| Composer | Done | Paperclip, drag-and-drop and Cmd+V for files and images. Images are downscaled to ≤2048 px and re-encoded to a ≤5 MB `data:` URL, stored under `attachments/`, and sent as `image_url` parts; UTF-8 text files ≤200 KB go inline as a fenced block; anything else is refused with a reason. `@mention` autocomplete in groups. |
| Overview | Done | Identity, description, memory summary; the profile's real skills (`/p/<profile>/v1/skills`, grouped by category, searchable above 12; categories starting with "." such as `.collision-retired` are hidden) and toolsets (`/v1/toolsets`), cached per bot with refresh and explicit empty/unavailable/error states; approval audit; delegated tasks if Hermes emits them. Imported template skills are listed as "Imported (not on server)". |
| Model per chat | Done | The Overview picker mirrors the bot's own profile at `/api/model/options`: one group per supplier the box lists, titled with the supplier's name (tags: default, preset, runs on the box, custom endpoint, sign-in needed), the profile's default supplier first, then the box's order; more than 16 models go in a submenu. Setup skeletons are hidden and counted in the footer. One checkmark under the supplier holding the current model. Unavailable models stay visible and disabled with the reason (sign-in needed, paid plan, checking the plan, rate-limited). Shows the chat's model (the box's session row wins over a stale local lock) and its supplier, or "not in the box's list". Every state has a one-line reason: no menu when capabilities, `model_options` or the route are missing or the profile is multiplex-off; redacted errors with Retry; the menu opens read-only without `session_model_lock` or before the first message. Live per profile: re-read when the Overview appears after 300 s, on another profile or session, or after a failure; the reload button forces; never polled. Choosing sends `POST /api/sessions/{id}/model` with `{model, provider}` only for a model the list offers, then reads the session back; a 409 is shown and nothing is stored. SwarmHub never sends, reads, stores or shows provider credentials, cannot unpin a chat (Hermes has no route), cannot choose a model before the first message, and does not edit the box's providers. `--render-snapshot` prints one model-menu line per `--bot`. Remembered defaults per bot: see "Model roles". |
| Model roles | Partial | Two roles per bot, resolved as bot override > SwarmHub default > box default: *Conversation* (applied to chats SwarmHub starts) and *Coding threads* (display only until coding threads land). **What is stored:** only a provider slug and model id — the SwarmHub-wide Conversation default in store.json (`modelDefaults`, this install only, empty until set) and per-bot settings (`modelSettings`: use SwarmHub default, box default, or a pair; set in the bot's settings → Models). **When applied:** once, when SwarmHub starts a main chat or a group member's session, through the existing lock: create the session plainly → read its row → `POST /api/sessions/{id}/model {model, provider}` only for a new session and only for a pair the bot's own profile lists; never on reviewer sessions, routines or a chat that already started (use **Switch this chat** in the Overview; the confirmation says Hermes cannot unpin a chat and a pinned chat has no fallback model). A refused per-bot override stops that send with a plain error; a refused SwarmHub default posts one note and the message goes out on the box default. Nothing configured means no extra request. Native sessions only. **Settings → Models:** the Conversation default (models listed from a chosen bot's profile after **Load**), per-bot rows with source tags and Edit…, and a read-only "Set on the box" block (box default per bot — "same on N of M" or "differs" — sub-agents, compaction, routines). Opening the pane fetches nothing; **Load** reads `/v1/capabilities`, `/api/model/options`, `/v1/toolsets` and the session row (GETs only, ≤4 at a time, no skills). The Overview adds Conversation / Coding threads / Sub-agents lines under the per-chat picker (see "Model per chat") and "This chat runs A; this bot's default is B." **What SwarmHub cannot set:** the sub-agent (`delegate_task`) model, compaction, routines' models and the box default live in the profile's `config.yaml`; SwarmHub never writes box config. `--render-snapshot` prints one roles line per `--bot`. |
| Routines | Done | The profile's Hermes cron jobs (`/p/<profile>/api/jobs*`): list, add/edit (hourly, daily/weekdays, weekly, raw cron or `every 30m`), pause/resume, Run now, Delete with confirm. Completion inbox: jobs are polled at most every 60 s; a new run's result lands in the chat as a "Routine finished" card, marks it unread and notifies under the usual rules, once per run. Servers without `/api/jobs` show the local list read-only. Imported routines stay local until "Create on server", which creates them paused. |
| Media | Done | Every attachment, inline image and link in the bot's chat and threads, newest first; clicking jumps to the message (opening the thread); links open in the browser. |
| Group chats | Done | **GROUPS** sidebar section; New group from ≥2 bots. `@Name` routes a message to the mentioned members, otherwise every member answers one after another, each in its own Hermes session for the group (`group-<group id>-<bot id>`) and given the transcript since its last reply (≤8,000 characters). Per-bot approvals, Stop and steer. Stored in store.json `{"version": 2, …}`; `AgentApp --migrate-store` converts headless. |
| Members | Done | A group's panel lists the owner and member bots (avatar, name, profile), adds/removes bots (sessions kept) and renames the group; a bot's Members tab shows its groups and "New group with …". Human workspace members are out of scope. |
| Computer | Done | Each bot has an optional web desktop address (noVNC or similar), set in its Computer tab or Settings → Computers: https, or plain http only on loopback; user info and password/token query items are refused because the address is stored in store.json. The tab shows reachability (`HEAD`, any HTTP status counts as up) with a recheck button; **Take over** opens the page in a separate window (WKWebView); **Open in browser** is the fallback. Watching versus controlling is decided by the desktop page itself. |
| Settings → Account | Done | Hermes server base URL, default key (Keychain), named profiles with Test & Discover; **Connected profiles** lists each server/profile the bots use with its bots, key state (from Keychain attributes, no prompt) and a **Test** button running the `--check-bots` probe (`/v1/models`, `/v1/capabilities`, `/api/jobs`, `/api/sessions`); "Add bots from box"; OpenClaw gateway URL. There is no user identity/workspace sign-in. |
| Settings → Appearance | Done | Dark (default), Light or System; accent colour (Graphite, Blue, Purple, Pink, Orange, Green, Teal) applied to the main window, Settings and the Computer window. |
| Settings → Notifications | Done | Global switch (off by default; asks macOS permission when turned on) plus a per-bot list using the same mute flag as the sidebar menu and bot settings. Delivery needs the app bundle and only fires while SwarmHub is in the background. |
| Settings → Computers | Done | One desktop address per bot with inline validation (see Computer). |
| Settings → Auto-review | Done | Explains the per-bot policy and lists every bot's mode (Ask me, Rules with count, Reviewer with name) with **Edit…** opening that bot's settings. |
| Settings → Usage | Done | On **Load**, reads each profile's `GET /api/sessions?limit=200&offset=…&include_children=true` (≤10 pages, GET only; needs `session_chat_streaming`) and sums `message_count`, `input_tokens`, `output_tokens`, `cache_read_tokens` per profile and in total for the last 24 h, 7 days or all time (a session counts in the period it started). Plain table plus a static bar list; profiles without a key or sessions API show why. `--check-bots` prints the same summary per bot. Costs are not shown. |
| Settings → Updates | Done | Version from Info.plist and the commit `package-release.sh` writes into `SOURCE.txt`; **Check for Updates** reads `https://api.github.com/repos/conrader/swarmhub/releases/latest` only when pressed; the user-agent is `SwarmHub/<version>` and says whether a newer tag exists, with a link to its github.com page. Nothing is downloaded. |
| Quick switcher | Partial | `Cmd+K` jumps to bots and groups, creates a bot, opens Settings; keyboard selection inside the list is not implemented. |
| Hermes | Done | Bots bound to Hermes profiles (`/p/<profile>/`, own Keychain key each); features chosen from `/v1/capabilities` and route presence; Sessions + SSE chat on 0.20.5/0.21.x, Chat Completions fallback on older servers; paged, non-destructive history merge; ask/rules/reviewer approvals with a local audit. A profile whose `/v1/models` id differs from its name (multiplexing off) is rejected and never routed to. Provider-backed reviewer runs remain unverified. |
| Grok Bot import | Done | `scripts/export-grokbot.py` reads the local Grok Bot cache (latest 62–200 entries per conversation plus the roster) into `agentapp-bot-bundle/v1` under `~/Documents/SwarmHub Grok Export/`; import from the sheet or `AgentApp --import-grok <folder>` binds each bot to `grok-<slug>`, maps avatar/accent and keeps a read-only, searchable "Imported from Grok Bot" archive per bot; re-import updates in place; the Grok group becomes a group chat. `AgentApp --import-keys <file>` loads keys from a 0600 file and deletes it. History older than the cache exists only on Grok's servers. |
| App icon | Assets ready | The SwarmHub "Swarm" icon: a white lead mark with a small blue, orange and green swarm, lit and shaded in 3D on a dark macOS rounded square. Sources in `Resources/AppIcon/` (`SwarmHub-icon.svg`, a simpler `SwarmHub-icon-small.svg` for 16 and 32 px, and a rendered `AppIcon.iconset`). Our own drawing, not Grok artwork. Building the `.icns` into the app bundle comes with the SwarmHub packaging. |
| Headless tools | Done | `--check-bots [--chat "<bot>" "<text>"]`, `--render-snapshot <dir> [--bot <name>]…`, `--import-grok`, `--import-keys`, `--migrate-store`. |
| OpenClaw | Not started | URL setting and protocol boundary only; the authenticated WebSocket RPC transport is not implemented. |
| Sub-agents | Partial | Inline lifecycle cards render if `subagent.*` events arrive, but the Hermes session stream does not emit them; no child transcript drill-down. |

There are no external package dependencies.

## Card syntax

Assistant replies (for example from a SOUL prompt) can use these Markdown conventions; SwarmHub renders them as cards and every other client still shows readable Markdown.

| Card | Syntax | Behaviour |
|---|---|---|
| Question with options | A fenced block with info string `choices`: non-list lines form the question, list lines (`- `, `* `, `+ `, `1. `, `1) `) are the options. Needs ≥2 options, else it stays a code block. | Clicking an option sends it as the user's reply; the card then shows the pick. |
| Trailing options | `<!-- choices -->` on its own line, followed by a numbered list (`1. ` / `1) `) that ends the message (≥2 items). An unmarked list stays ordinary Markdown. | Same as above; the text before the marker stays as prose. |
| Draft | A fenced block with info string `draft`; optional leading `to:` and `subject:` header lines (case-insensitive), one blank line, then the body. | **Send** posts "Send it" to the bot (the bot does the sending, under its approval policy); **Copy** copies the draft. |
| Link pills | Any bare `http(s)://` URL in prose (not inside a Markdown link, `<…>` or inline code). | A pill per URL under the paragraph; opens in the browser. |
| Image | `![alt](https://…)` or `![alt](data:image/png;base64,…)`. Other schemes stay text. | Shown inline; click to preview. |

Example:

````markdown
I drafted the reply.

```draft
to: Maya <maya@example.com>
subject: Launch update

Hi Maya, the rollout is ready for review.
```

```choices
When should I send it?
- Now
- Tomorrow 9:00
```
````

## Grok Bot template import

Use the import button beside **New bot** to preview and import one user-owned template from an exported JSON file or a pasted share link. A link is accepted only when its response is JSON; AgentApp does not scrape share pages and instead asks for an exported file. The parser tolerates missing and unknown fields and the bundled test fixture is entirely synthetic.

The preview accounts for bot metadata, instructions, memories, Markdown skills, routines, connector IDs, the optional getting-started skill, and rejected sensitive data. Each item is labelled mapped, converted, skipped, or unsupported with a reason. No bot is created before confirmation. Imported cron routines (created on the server only from the Routines tab, paused) and the getting-started skill remain disabled, and connector mappings are requests only—they do not grant access.

Imported persona text becomes the Hermes session system prompt. Memories, Markdown skill sources, disabled cron definitions, and connector requests are persisted as inert bot configuration for later runtime provisioning. The Hermes API currently used by AgentApp does not expose safe skill/cron/profile installation, so the preview reports that limit; event triggers and unknown connector IDs are not carried over. Token-, key-, password-, credential-, authorization-, cookie-, private-key-, and common secret-shaped values are removed before mapping and never included in the report.

Imported bots run on your default Hermes profile, so that profile's tools, memory, and skills apply. A template with a slug `S` is bound instead to profile `grok-S` (or `S`) when a key for that profile is in the Keychain; the import report's "Hermes profile" row names the profile.

### Known limitations (template import)

- Share-link loading still needs transport, redirect, timeout, and streaming-size hardening (L1).
- Some malformed items are silently dropped, and schedule strings are not validated (L2–L3).
- Imported configuration has no complete activation/provisioning UI yet (L5).
- Future fields added to nested persisted types may require explicit decoding defaults (L6).
- Remaining parser modularity and hygiene work is tracked in [the template-import review](REVIEW-template-import.md).

## Hermes Agent setup

Checked against Hermes Agent v0.21.7 (`v2026.9.24`) tagged source and a throwaway gateway on 2026-10-13:

- Enable the server with `API_SERVER_ENABLED=true` and set `API_SERVER_KEY` in `~/.hermes/.env`.
- Start it with `hermes gateway run`; its documented default is `http://127.0.0.1:8642`.
- AgentApp uses `/v1/capabilities`, native `/api/sessions/*` resources and session SSE, plus `/v1/runs/{id}/stop` and `/approval`.
- The Overview reads `/v1/skills`, `/v1/toolsets` and `/api/model/options` and switches a chat's model with `POST /api/sessions/{id}/model`, each only when `/v1/capabilities` advertises it (`skills_api`, the `toolsets` endpoint, `model_options`, `session_model_lock`) and the route answers; same shapes on 0.20.5 (`v2026.8.19`) and 0.21.x.
- Connection testing calls authenticated `/health/detailed` and displays the server version.
- Older servers without capabilities fall back to OpenAI-compatible `POST /v1/chat/completions` SSE before any unsupported Sessions call.

See [the integration note](hermes-integration.md) and [captured v0.21.7 evidence](hermes-v0.21.7-evidence.md) for source excerpts, a real-gateway transcript, and verification limits.

Select **Hermes Agent** when editing a bot, then enter the base URL and key in Settings. Secrets are stored in macOS Keychain and never written to the repository or JSON store.

## OpenClaw status

OpenClaw is an explicit partial adapter. Its documented Gateway is a WebSocket RPC protocol—not an OpenAI-compatible HTTP endpoint—and uses `chat.send`, `chat.history`, `sessions.list`, plus event and approval families. URL configuration and the shared protocol boundary are present; authentication, request framing, event subscription, cancellation, and approvals remain to implement.

Sources: [Gateway protocol](https://docs.openclaw.ai/gateway/protocol), [WebChat methods](https://docs.openclaw.ai/web/webchat).

## Credits

Bot avatars use [BotAvatarsKit](https://github.com/Jakubantalik/Libraries.dev/tree/main/packages/bot-avatars) by Jakub Antalik (Libraries.dev, MIT), vendored at a pinned commit in `Vendor/BotAvatarsKit`; see `THIRD-PARTY-NOTICES.md` and Settings → Updates → Acknowledgements.

## Architecture

```text
Vendor/BotAvatarsKit/  pinned MIT BotAvatarsKit (Swift 5 target, macOS patches in VENDORED.md)
Sources/AgentApp/
├── Models/       bot, message, approval, sub-agent and event types
├── Backends/     protocol plus Mock, Hermes and OpenClaw adapters
├── Stores/       app state, atomic local persistence and Keychain
├── TemplateImport/ reusable parsing, sanitizing and mapping pipeline
├── GrokImport/   bot-bundle loader, Grok history archive, avatar table, headless CLI
├── Avatars/      bot marks: Grok words, default-look rule, migration, kit body map, motion, still/live views
└── Views/        sidebar, chat, composer, approvals, desktop and settings
```

JSON was chosen over SwiftData for this prototype to avoid a runtime/database dependency and keep startup small. Writes are atomic. For very large durable histories, the next storage iteration should use SQLite with indexed, paged message queries; the current lazy UI remains efficient, but decoding an entire JSON history is not the final 5,000-message storage design.

## Performance measurement

Measured on the supplied Mac with a clean process launch and the Xcode 16.2 compiler, using:

```bash
./scripts/build.sh
AGENTAPP_BENCHMARK=1 /usr/bin/time -l .build/debug/AgentApp
```

Current result after the parity pass: **0.01 s warm process launch** and **12.1 MB peak resident memory at app initialization** (snapshot launches reported 12.2 MB). This benchmark exits immediately after app-state initialization; it does not claim first-frame timing. The app also prints initialization memory on normal launches.

## Screenshots

![AgentApp default dark appearance](screenshot.png)

The managed session has no WindowServer/display access, so the repository includes a deterministic off-screen renderer for the actual SwiftUI hierarchy. Recreate the default capture with:

```bash
AGENTAPP_APPEARANCE=Dark AGENTAPP_SNAPSHOT="$PWD/docs/screenshot.png" .build/debug/AgentApp
```

The normal interactive app does not invoke this renderer.

## Next steps

1. Implement OpenClaw's authenticated WebSocket handshake and RPC/event mapping.
2. Add Hermes child-session drill-down/steer controls, attachments, scheduling, and reconnect-to-active-run support.
3. Account identity (no workspace sign-in exists), cost figures in Usage, and downloadable releases for Updates.
4. Move long histories to paged SQLite and add accessibility/UI tests.

## Roadmap

Phase briefs live in [briefs/](../briefs/); [PLAN.md](../PLAN.md) holds the table and the standing constraints.

| Phase | What | State |
|---|---|---|
| P14 | No title bar; the right column slides like the sidebar | Merged |
| P15 | Bot marks (BotAvatarsKit) with motion by context | Merged |
| P18 | SwarmHub branding; launch never selects a hidden bot (the Atlas fix) | Merged |
| P20 | Sidebar like Grok Bot: 36 pt marks, name plus latest message, flat list | Planned (after P18) |
| P19 | PDF and document attachments, read on the Mac; fixes the silent 64K text truncation | Planned |
| P16 | No reply is lost: truthful turns, reconcile from the box, Retry | Planned (brief in `briefs/P16.md`) |
| P17 | Model choices in bot settings come from the bot's own Hermes profile or OpenClaw gateway | Designing |
| P13 C | Coding threads and the sub-agent model | Waiting for go |
| P12 | Connect OpenClaw | Planned |
| P21 | Simple settings: everything difficult moved to Advanced; plain first-run "connect your box" | Designing |
