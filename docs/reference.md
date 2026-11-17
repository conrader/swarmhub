# SwarmHub technical reference

For the macOS app in `Sources/AgentApp`. The bridge and the browser workspace have their own reference in [HerdrWorkspace/README.md](../HerdrWorkspace/README.md).

## Build and run

Needs a Mac with Xcode (Swift 6) and macOS 14 or later.

```sh
./scripts/run.sh        # build (debug) and run the bare executable
./scripts/build.sh      # build only; SWARMHUB_BUILD_CONFIGURATION=release for a release build
swift test              # the Mac tests in Tests/AgentAppTests
```

`scripts/build.sh` uses SwiftPM when `xcrun` finds the macOS SDK and falls back to calling `swiftc` directly otherwise. Both link Sparkle and the vendored BotAvatarsKit. `SWARMHUB_FORCE_SWIFTC=1` takes the fallback on purpose.

`scripts/package-release.sh` builds a release `.app` under `dist/`, embeds and signs Sparkle, and notarizes when `SWARMHUB_NOTARY_PROFILE` is set. Release steps are in [Automatic updates](updates.md).

The Swift package (`Package.swift`) has two targets besides the tests: `AgentApp` and `BotAvatarsKit`. Its only remote dependency is Sparkle.

## Architecture

[Architecture](architecture.md) describes the whole system: the Mac app, the bridge, Herdr Core and the agent programs, with drawings. The drawings are written by `python3 docs/diagrams/generate.py` (add `--png` for PNG renders; that needs Chrome or Chromium, and Pillow). This section is about the Mac app's own folders.

| Folder in `Sources/AgentApp` | What it holds |
| --- | --- |
| `Backends` | `AgentBackend`, the protocol for whatever answers a bot. `HerdrBackend` is the one real implementation; `MockBackend` answers locally for the sample agents. `HerdrClient` and the other `Herdr*` files talk to the bridge. |
| `Stores` | `AppStore` and its extensions: bots, groups, turns, the message queue, servers, saving. |
| `Models` | Bots, messages, groups, turn state, cards. |
| `Views` | SwiftUI views: sidebar, chat, composer, Details panel, settings. |
| `Setup` | The setup window and the words it uses. |
| `GrokExport`, `GrokImport`, `TemplateImport` | Reading Grok Bot's data and templates, and the command-line entry points. |
| `Avatars`, `Voice` | Avatar drawing and settings; dictation through deAPI. |

### How a message reaches an agent

1. `HerdrBackend.send` takes the newest user message. Earlier messages are not sent: the agent keeps its own conversation.
2. `HerdrClient.deliver` types the message into the bot's running agent (`POST /api/agents/{address}/{created_ms}/messages`), or starts one from the bot's template with the bot's instructions and the message as its first task (`POST /api/agents`).
3. `HerdrClient.reply` follows the turn on the bridge's event stream (`GET /api/agents/{address}/{created_ms}/events`). When the stream cannot be opened or keeps breaking, it polls the saved rows and the reply so far instead.
4. The reply is final when the agent's own hook has saved it on the bridge.

Every request carries the server's access token as a bearer token. The bridge listens on loopback only and refuses a request whose `Host` is not `127.0.0.1:<port>` or `localhost:<port>`, so a remote server is reached through a forward of the same port number.

A message is cut to what the bridge accepts: plain text, up to 16 KB for a first task including the bot's instructions.

## Files on disk

The app keeps its data in `~/Library/Application Support/AgentApp/`:

| File or folder | Contents |
| --- | --- |
| `store.json` | Bots, groups and chats. |
| `runtime.sqlite` | The index of saved documents and the queue of messages waiting to be sent. |
| `attachments/` | Attached images. |
| `artifacts/` | Saved documents. |
| `grok-history/` | Read-only history imported from Grok Bot, one file per bot or group. |

A `store.json` that cannot be read is moved aside as `store.json.corrupt-<time>`, and the app offers to restore the newest readable copy. A store from an older version that holds bots of a removed backend is copied to `store.json.before-herdr-only-<time>` before those bots are left out.

The server list, each bot's server, template and model, and other preferences are in the app's `UserDefaults`. Access tokens and the deAPI key are in the Keychain. For an SSH server the app saves the path of the key file, never the key.

## Environment

| Variable | Effect |
| --- | --- |
| `SWARMHUB_HERDR_TOKEN` | Access token for the first server, used only when the Keychain has none. For development launches. |
| `SWARMHUB_DISABLE_UPDATES=1` | Turns the automatic updater off for this launch. |
| `SWARMHUB_BUILD_CONFIGURATION` | `debug` or `release`, read by `scripts/build.sh`. |

## Command-line flags

These run without a window and exit:

| Flag | What it does |
| --- | --- |
| `--import-grok <export folder \| index.json \| bundle.json>` | Imports a Grok Bot export into the store. |
| `--grok-fetch --mode recent\|full [--bots <names>] [--store <store.json>] [--report <file>]` | Fetches Grok Bot history. |
| `--grok-probe [--live] [--report <file>]` | Checks whether Grok Bot's data still has the expected shape. |
| `--grok-parity <python export folder> [--cache <folder>]` | Compares the app's own bundles with those `scripts/export-grokbot.py` wrote. |
| `--migrate-store` | Loads and saves the store in the current format. |
| `--probe-attachment <file>` | Reads a PDF, RTF, DOC or DOCX like the composer does and prints counts. No network. |
| `--render-snapshot <dir> [--bot "<name>"]...` | Renders the window to image files. |
| `--render-setup <dir> [--light]` | Renders the setup steps, Settings pages, chats and helper views from a synthetic store with sample content, dark unless `--light` is given. No network, no Keychain. The screens in the README and the guide (`docs/screenshots`) come from it. |

Two flags apply to a normal launch with a window: `--ui-smoke <report.json>` and `--setup-preview`.

## Grok Bot export tools

`scripts/export-grokbot.py` writes the `agentapp-bot-bundle/v1` format ([spec](agentapp-bot-bundle-v1.md)) from Grok Bot's local cache. `scripts/grokbot_server.py`, `scripts/grokbot_staged.py` and `scripts/export_grok_local.py` belong to it. The app has its own Swift implementation of the same export; the Swift tests and `--grok-parity` compare the two. The Python tests run with:

```sh
PYTHONPATH=scripts python3 -B -m unittest test_export_grokbot test_grokbot_server test_grokbot_staged
```

Findings from reading Grok Bot's protocol are in [P8a-findings.md](P8a-findings.md) and [P10-spike-findings.md](P10-spike-findings.md).

## Card syntax

A reply can use these Markdown conventions. The app draws them as cards; elsewhere they read as ordinary Markdown.

| Card | Syntax | Behaviour |
| --- | --- | --- |
| Question with options | A fenced block with info string `choices`: non-list lines form the question, list lines (`- `, `* `, `+ `, `1. `, `1) `) are the options. It needs at least two options, else it stays a code block. | Choosing an option sends it as your reply. |
| Trailing options | `<!-- choices -->` on its own line, followed by a numbered list that ends the message. | The same. An unmarked list stays ordinary Markdown. |
| Draft | A fenced block with info string `draft`; optional leading `to:` and `subject:` lines, one blank line, then the body. | **Send** sends "Send it" to the bot; the app itself sends nothing anywhere else. **Copy** copies the draft. |
| Link pills | A bare `http(s)://` URL in prose. | A pill per link under the paragraph. |
| Image | `![alt](https://…)` or `![alt](data:image/…)`. | Shown inline. |

A fenced block with info string `swarmhub` is how a bot's agent asks the app for something (a new bot, or the main bot's help). The chat shows it as one folded line.

## Other code in this repository

- `HerdrWorkspace/`: the bridge and browser workspace, in Rust. Build and test instructions are in its README.
- `Apps/iOS-seed`: starting material for a future iPhone app (two SwiftUI source files, the app icon, screen drawings). It is not an app and nothing builds it; its [README](../Apps/iOS-seed/README.md) says what a phone app needs first.
- `scripts/export-grokbot.py` and the other Grok Bot export tools, with their tests (`scripts/test_*.py`). `bash Tests/Scripts/pysuites.sh <worktree> <log dir>` runs every Python test in `scripts/`.

## Credits

Bot avatars use BotAvatarsKit by Jakub Antalik (Libraries.dev), MIT. See [Third-party notices](../THIRD-PARTY-NOTICES.md).
