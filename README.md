# Torvli

A native macOS prototype for chatting with user-owned agent harnesses. There is no built-in model. The user-facing name is defined once in `AppConstants.name`; the Swift package, module and executable keep the original `AgentApp` codename, and the bundle identifier and Keychain service stay `com.konrad.agentapp` so existing settings and keys carry over.

## Build and run

Requirements: macOS 14+, Xcode 16.2, Swift 6.

```bash
./scripts/build.sh
./scripts/run.sh
```

`scripts/build.sh` normally delegates to `swift build`. It also contains a direct Xcode 16.2 compiler fallback because the current host's `xcrun` crashes while loading `CoreDevice.framework`. The fallback verifies that the production target compiles, but it does not run SwiftPM tests.

The Swift unit tests have never executed on this host. Both `swift test` and `xcodebuild test` fail before package compilation because Xcode 16.2's `CoreDevice.framework` requests `_XPCTypeBool`, which the installed macOS `Mercury.framework` does not export. Saved build and runner logs are under `docs/hermes-fix5-*.log`. A later MacBook install must not be trusted until its test runner executes the suite successfully.

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

This pass recreates the product structure and interaction patterns with original SwiftUI code, SF Symbols, and original assets. It does not ship extracted artwork, fonts, icons, strings, or other assets from Grok Bot.

| Area | Status | Notes |
|---|---|---|
| Three-column layout | Done | Bot sidebar, centred chat, and an open-by-default right panel; `Cmd+Shift+I` collapses it. |
| Bot sidebar | Partial | Round avatars, unread dots, new/hidden bots, account/settings, and context actions work, including **Mark as Unread** (a manual flag kept in store.json that survives restarts and clears when the chat is opened); labels are fixed sections rather than user-defined groups. |
| Original bot faces | Partial | 12 colour variants are drawn with SwiftUI `Canvas`; nine original DMT-generated clay PNGs are also selectable. |
| Core chat | Partial | Text, user bubbles, basic Markdown/code (with Copy), streaming, Stop/cancellation, and lazy rendering work. **Steer:** while a turn streams and the server reports `run_steer`, Send (or Enter) posts the text to `POST /v1/runs/{run_id}/steer` as `{"input": text}` and shows it as a dashed "Steered the running turn" bubble; a refusal (e.g. 409 once the run stops taking input) marks the bubble "Steer not delivered" with the reason. Without `run_steer` sending stays disabled while a turn runs (Stop only), as before. Markdown coverage is limited. |
| Replies and tapbacks | Done | Quote replies as before. **Reply in thread** on an assistant message forks the bot's session (`POST /api/sessions/{id}/fork` with `{"id": "agentapp_thread_<uuid>"}`) and opens the thread as a sub-conversation of the same bot, shown under the source message as "N replies"; the composer then sends into the fork. Hermes has no "fork at message" parameter: the fork carries the whole transcript as it stood when the thread was opened, and Hermes marks the source session `branched` (it keeps working). The action is hidden without `session_fork`. Tapbacks (👍 ❤️ 😂 ‼️ ?) toggle on/off and are saved per message in store.json at once (local only, never sent). |
| Inline content | Done | Assistant Markdown is parsed into our own cards: question-with-options, draft (Send posts "Send it" to the bot; Copy copies it), link pills under paragraphs with bare URLs, and inline Markdown images (http(s) or `data:image/…`, click to preview). Picks and sends are remembered on the message. Syntax: see "Card syntax" below. The demo-only voice/attachment/links cards remain local prototypes. |
| Composer | Done | Paperclip (multiple files), drag-and-drop onto the chat, and Cmd+V paste of files or images. Images (PNG/JPEG/GIF/WebP) are downscaled to ≤2048 px on the long edge and re-encoded until the `data:image/…` URL is ≤5 MB, stored under `attachments/` next to store.json, and sent as `image_url` content parts — as the `input` part list on the session stream (`_session_chat_user_message` → `_normalize_multimodal_content`) or as the last user message's content parts on Chat Completions. Text files ≤200 KB (UTF-8, no NUL bytes) are sent inline as `File: <name>` plus a fenced block; anything else is refused with a clear message. Bubbles show thumbnails/file chips; click to preview. |
| Overview | Done | Identity, description and memory summary; for Hermes bots the profile's real skills (`/p/<profile>/v1/skills`: name, one-line description, grouped by category, searchable above 12) and toolsets (`/v1/toolsets`: label, description, On/Off/Needs setup), cached per bot for the app session with a refresh button and explicit empty/unavailable/error states. Locally imported template skills are listed separately as "Imported (not on server)". |
| Model per chat | Done | Overview shows the chat's model (confirmed lock for this session, else the session row's `model`, else the server default from `/api/model/options`) and a picker of credentialed providers → models with the current one checked. Choosing one sends `POST /api/sessions/{id}/model` with `{model, provider}` only (no credentials); a 409 (unroutable, Hermes refuses a silent fallback) is shown and nothing is stored. The confirmed lock is remembered per session. The picker is hidden when `model_options` is false or the route 404s, and read-only without `session_model_lock`. |
| Routines | Done | Backed by the profile's Hermes cron jobs (`/p/<profile>/api/jobs*`, profile key): list (paused included) with name, human schedule, state, last/next run as relative times and last error; add/edit sheet (hourly, daily/weekdays at HH:MM, weekly on a day at HH:MM, or raw cron / `every 30m` text; prompt); pause/resume toggle (optimistic, reconciled with the server's job), Run now, Delete with an inline confirm. Run now on a paused routine pauses it again after that run (Hermes re-enables a job it runs). Completion inbox: while the app runs each Hermes bot's jobs are polled at most every 60 s (backing off on errors); when a job's `last_run_at` advances its run session (`cron_<job id>_…`, from `/api/sessions?source=cron`) is read and a "Routine finished" card (name, status, first ~600 characters, error) lands in the chat, marks it unread and notifies under the usual rules. The last seen run per job is kept in store.json, so a run is carded once. A server without `/api/jobs` shows "This Hermes server has no jobs API" and the local list stays read-only. Imported routines stay local ("Imported — not on server") until "Create on server", which creates them paused (create, then pause; deleted again if the pause fails). `--check-bots` lists each bot's jobs (read-only). |
| Media | Done | Lists every attachment, inline image and link (Markdown links and bare URLs, not code) in the bot's chat and its threads, newest first, with thumbnails; clicking an item jumps to its message (opening the thread if needed); links also open in the browser. |
| Computer | Partial | Configurable noVNC preview and expanded sheet exist; view-only and take-over modes are not distinct. |
| Members | Stub | Local owner/agent display; workspace membership provider is TODO. |
| Settings | Partial | Seven sections exist. Accent is not applied; account, policy sync, metering, and updater services are stubs. |
| Quick switcher | Partial | `Cmd+K` jumps to bots and creates a bot; Settings uses a compatibility selector and keyboard selection is not implemented. |
| Notifications | Partial | Global (off by default) and per-bot controls exist. Delivery is bundle-safe and unavailable from the bare SwiftPM executable. |
| Hermes | Partial | v0.21.7 Sessions/SSE chat, capped non-destructive paged history merging, per-run immediate local Stop plus background run Stop, per-bot ask/rules/reviewer approvals with local audit, internal tool status handling, Keychain auth, health checks, and configured profiles are implemented. A failed or timed-out server Stop is reported beside the stopped turn without changing a newer run. Approval is disabled when Hermes supplies no command text. 0.16–0.20.x uses Chat Completions without Sessions calls. Native and legacy fixtures previously passed outside the managed sandbox; this pass records its rerun under `docs/approvals-fix4-*.log`. Provider-backed reviewer behavior remains unverified. |
| Hermes profiles | Partial | Each bot is bound to one Hermes profile (`/p/<profile>/`) with its own Keychain key; Settings → "Add bots from box" takes `profile=key` lines, probes each profile and names new bots from the slug (`grok-jarvis` → Jarvis). A profile whose `/v1/models` id differs from its name (gateway `multiplex_profiles` off) is rejected and never routed to. |
| Grok Bot import | Partial | `scripts/export-grokbot.py` reads the local Grok Bot app cache (latest 62–200 entries per conversation plus the roster) into `agentapp-bot-bundle/v1` under `~/Documents/Torvli Grok Export/`; the app imports it from the import sheet or headless with `AgentApp --import-grok <folder>`. Each bot is bound to `grok-<slug>` at `https://konrad.agenthut.net/v1` (key from Keychain `hermes.grok-<slug>`; a missing key shows "Add key"), gets an own avatar/accent from Grok's shape/colour words, and a read-only, searchable "Grok history" archive stored per bot in `grok-history/` next to store.json. Re-import updates in place. The group conversation is an archived read-only chat (no group chats yet). `AgentApp --import-keys <file>` loads `profile=key` lines from a 0600 file into the Keychain and deletes the file. Older history that only Grok's servers hold is not exported. |
| OpenClaw | Stub | Protocol/configuration exist; authenticated WebSocket RPC remains TODO. |
| Sub-agents | Stub | Inline lifecycle cards are supported if emitted, but the checked v0.21.7 HTTP session stream does not emit `subagent.start`/`subagent.complete`. Child transcript drill-down and controls are not implemented. |

There are no external package dependencies.

## Card syntax

Assistant replies (for example from a SOUL prompt) can use these Markdown conventions; Torvli renders them as cards and every other client still shows readable Markdown.

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
- Remaining parser modularity and hygiene work is tracked in [the template-import review](docs/REVIEW-template-import.md).

## Hermes Agent setup

Checked against Hermes Agent v0.21.7 (`v2026.9.24`) tagged source and a throwaway gateway on 2026-10-13:

- Enable the server with `API_SERVER_ENABLED=true` and set `API_SERVER_KEY` in `~/.hermes/.env`.
- Start it with `hermes gateway run`; its documented default is `http://127.0.0.1:8642`.
- AgentApp uses `/v1/capabilities`, native `/api/sessions/*` resources and session SSE, plus `/v1/runs/{id}/stop` and `/approval`.
- The Overview reads `/v1/skills`, `/v1/toolsets` and `/api/model/options` and switches a chat's model with `POST /api/sessions/{id}/model`, each only when `/v1/capabilities` advertises it (`skills_api`, the `toolsets` endpoint, `model_options`, `session_model_lock`) and the route answers; same shapes on 0.20.5 (`v2026.8.19`) and 0.21.x.
- Connection testing calls authenticated `/health/detailed` and displays the server version.
- Older servers without capabilities fall back to OpenAI-compatible `POST /v1/chat/completions` SSE before any unsupported Sessions call.

See [the integration note](docs/hermes-integration.md) and [captured v0.21.7 evidence](docs/hermes-v0.21.7-evidence.md) for source excerpts, a real-gateway transcript, and verification limits.

Select **Hermes Agent** when editing a bot, then enter the base URL and key in Settings. Secrets are stored in macOS Keychain and never written to the repository or JSON store.

## OpenClaw status

OpenClaw is an explicit partial adapter. Its documented Gateway is a WebSocket RPC protocol—not an OpenAI-compatible HTTP endpoint—and uses `chat.send`, `chat.history`, `sessions.list`, plus event and approval families. URL configuration and the shared protocol boundary are present; authentication, request framing, event subscription, cancellation, and approvals remain to implement.

Sources: [Gateway protocol](https://docs.openclaw.ai/gateway/protocol), [WebChat methods](https://docs.openclaw.ai/web/webchat).

## Architecture

```text
Sources/AgentApp/
├── Models/       bot, message, approval, sub-agent and event types
├── Backends/     protocol plus Mock, Hermes and OpenClaw adapters
├── Stores/       app state, atomic local persistence and Keychain
├── TemplateImport/ reusable parsing, sanitizing and mapping pipeline
├── GrokImport/   bot-bundle loader, Grok history archive, avatar table, headless CLI
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

![AgentApp default dark appearance](docs/screenshot.png)

The managed session has no WindowServer/display access, so the repository includes a deterministic off-screen renderer for the actual SwiftUI hierarchy. Recreate the default capture with:

```bash
AGENTAPP_APPEARANCE=Dark AGENTAPP_SNAPSHOT="$PWD/docs/screenshot.png" .build/debug/AgentApp
```

The normal interactive app does not invoke this renderer.

## Next steps

1. Implement OpenClaw's authenticated WebSocket handshake and RPC/event mapping.
2. Add Hermes child-session drill-down/steer controls, attachments, scheduling, and reconnect-to-active-run support.
3. Connect members, account identity, usage metering, and update services.
4. Move long histories to paged SQLite and add accessibility/UI tests, app signing, and a real app icon.
