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
| Bot sidebar | Partial | Round avatars, unread dots, new/hidden bots, account/settings, and context actions work; labels are fixed sections rather than user-defined groups. |
| Original bot faces | Partial | 12 colour variants are drawn with SwiftUI `Canvas`; nine original DMT-generated clay PNGs are also selectable. |
| Core chat | Partial | Text, user bubbles, basic Markdown/code, streaming, Stop/cancellation, and lazy rendering work; Markdown coverage and code-copy interaction are limited. |
| Replies and tapbacks | Partial | Reply context and emoji reactions are stored on messages, but replies are display-only and reaction edits are not saved immediately. |
| Inline content | Stub | Cards are local visual prototypes. Options, links, voice, images, and attachments do not perform backend actions; draft-email Send is explicitly disabled. |
| Composer | Stub | Text send, Enter/Shift+Enter, Stop, and a file picker exist; selected files are only inserted as attachment text and are not uploaded. |
| Overview | Done | Identity, description, memory summary, and skills. |
| Routines | Stub | Create, pause, schedule/trigger, and last-run UI use local mock data; backend scheduling is TODO. |
| Media | Partial | A grid is sourced from attachment/image messages, but it uses placeholders and items do not open. |
| Computer | Partial | Configurable noVNC preview and expanded sheet exist; view-only and take-over modes are not distinct. |
| Members | Stub | Local owner/agent display; workspace membership provider is TODO. |
| Settings | Partial | Seven sections exist. Accent is not applied; account, policy sync, metering, and updater services are stubs. |
| Quick switcher | Partial | `Cmd+K` jumps to bots and creates a bot; Settings uses a compatibility selector and keyboard selection is not implemented. |
| Notifications | Partial | Global (off by default) and per-bot controls exist. Delivery is bundle-safe and unavailable from the bare SwiftPM executable. |
| Hermes | Partial | v0.21.7 Sessions/SSE chat, capped non-destructive paged history merging, per-run immediate local Stop plus background run Stop, per-bot ask/rules/reviewer approvals with local audit, internal tool status handling, Keychain auth, health checks, and configured profiles are implemented. A failed or timed-out server Stop is reported beside the stopped turn without changing a newer run. Approval is disabled when Hermes supplies no command text. 0.16–0.20.x uses Chat Completions without Sessions calls. Native and legacy fixtures previously passed outside the managed sandbox; this pass records its rerun under `docs/approvals-fix4-*.log`. Provider-backed reviewer behavior remains unverified. |
| OpenClaw | Stub | Protocol/configuration exist; authenticated WebSocket RPC remains TODO. |
| Sub-agents | Stub | Inline lifecycle cards are supported if emitted, but the checked v0.21.7 HTTP session stream does not emit `subagent.start`/`subagent.complete`. Child transcript drill-down and controls are not implemented. |

There are no external package dependencies.

## Grok Bot template import

Use the import button beside **New bot** to preview and import one user-owned template from an exported JSON file or a pasted share link. A link is accepted only when its response is JSON; AgentApp does not scrape share pages and instead asks for an exported file. The parser tolerates missing and unknown fields and the bundled test fixture is entirely synthetic.

The preview accounts for bot metadata, instructions, memories, Markdown skills, routines, connector IDs, the optional getting-started skill, and rejected sensitive data. Each item is labelled mapped, converted, skipped, or unsupported with a reason. No bot is created before confirmation. Imported cron routines and the getting-started skill remain disabled, and connector mappings are requests only—they do not grant access.

Imported persona text becomes the Hermes session system prompt. Memories, Markdown skill sources, disabled cron definitions, and connector requests are persisted as inert bot configuration for later runtime provisioning. The Hermes API currently used by AgentApp does not expose safe skill/cron/profile installation, so the preview reports that limit; event triggers and unknown connector IDs are not carried over. Token-, key-, password-, credential-, authorization-, cookie-, private-key-, and common secret-shaped values are removed before mapping and never included in the report.

Imported bots run on your shared default Hermes profile, so that profile's tools, memory, and skills apply.

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
