# AgentApp

A native macOS prototype for chatting with user-owned agent harnesses. There is no built-in model. The working name is defined once in `AppConstants.name` so it can be renamed later.

## Build and run

Requirements: macOS 14+, Xcode 16.2, Swift 6.

```bash
./scripts/build.sh
./scripts/run.sh
```

`scripts/build.sh` normally delegates to `swift build`. It also contains a direct Xcode 16.2 compiler fallback because the current host's `xcrun` crashes while loading `CoreDevice.framework`. The fallback was used to verify this prototype.

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
| Hermes | Partial | SSE chat, auth, Keychain storage, and health check work; progress events are parsed but not displayed, and Runs API features remain TODO. |
| OpenClaw | Stub | Protocol/configuration exist; authenticated WebSocket RPC remains TODO. |
| Sub-agents | Stub | Event types exist, but incoming sub-agent events are not displayed and there is no panel yet. |

There are no external package dependencies.

## Hermes Agent setup

Verified against the public Hermes API-server documentation and repository plan on 2026-10-11:

- Enable the server with `API_SERVER_ENABLED=true` and set `API_SERVER_KEY` in `~/.hermes/.env`.
- Start it with `hermes gateway`; its documented default is `http://127.0.0.1:8642`.
- AgentApp defaults to `http://127.0.0.1:8642/v1` and sends `POST /v1/chat/completions` with `model: hermes-agent`, `stream: true`, and `Authorization: Bearer <key>`.
- Streaming uses OpenAI-compatible SSE chunks. The adapter also recognizes Hermes' `event: hermes.tool.progress` extension.
- Connection testing calls `/health`.

Sources: [Hermes API Server guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), [Hermes API-server plan](https://github.com/hermes-agent-org/hermes/blob/main/.plans/openai-api-server.md).

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
2. Upgrade Hermes to its Runs API for reconnectable sessions, attachment upload, scheduling, and real approval resolution.
3. Connect members, account identity, auto-review policy, usage metering, and update services.
4. Move long histories to paged SQLite and add accessibility/UI tests, app signing, and a real app icon.
