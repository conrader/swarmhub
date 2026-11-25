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

`scripts/package-release.sh` builds a release ZIP under `dist/`, embeds and signs Sparkle, and notarizes when `SWARMHUB_NOTARY_PROFILE` is set. `scripts/release.sh` makes a whole release from it: the app archive, the appcast, and the signed manifest for the bridge's programs, which `scripts/package-workspace.sh` builds: one on a Linux build machine, and two on the Mac (Apple silicon and Intel), which it also signs. The release steps, and `Tests/Scripts/update-rehearsal.sh`, which rehearses an update without credentials, are in [Updates](updates.md#releasing).

The Swift package (`Package.swift`) has two targets besides the tests: `AgentApp` and `BotAvatarsKit`. Its only remote dependency is Sparkle.

## Architecture

[Architecture](architecture.md) describes the whole system: the Mac app, the bridge, Herdr Core and the agent programs, with drawings. The drawings are written by `python3 docs/diagrams/generate.py` (add `--png` for PNG renders; that needs Chrome or Chromium, and Pillow). This section is about the Mac app's own folders. The code keeps the technical names; the interface says "bot", "AI" for an agent program, and "helper".

| Folder in `Sources/AgentApp` | What it holds |
| --- | --- |
| `Backends` | `AgentBackend`, the protocol for whatever answers a bot. `HerdrBackend` is the one real implementation; `MockBackend` answers locally for the sample bots. `HerdrClient` and the other `Herdr*` files talk to the bridge. |
| `Stores` | `AppStore` and its extensions: bots, groups, turns, the message queue, servers, the first conversation and "About you", saving. `AppUpdater` (Sparkle) and `SoftwareUpdateModel` (the servers' updates). |
| `Models` | Bots, messages, groups, turn state, cards. |
| `Views` | SwiftUI views: sidebar, chat, composer, Details panel, Settings and its panes (General, Servers, Software Update, About). |
| `Setup` | The setup window, and the visible words of the setup window and Settings (`WizardCopy`, `SetupCopy`, `SimpleCopy`, `SettingsLayout`). |
| `GrokExport`, `GrokImport`, `TemplateImport` | Reading Grok Bot's data and templates, and the command-line entry points. |
| `Avatars` | Avatar drawing and settings. |

### How a message reaches an agent

1. `HerdrBackend.send` takes the newest user message. Earlier messages are not sent: the agent keeps its own conversation.
2. `HerdrClient.deliver` types the message into the bot's running agent (`POST /api/agents/{address}/{created_ms}/messages`), or starts one from the bot's template with the bot's instructions, "About you", the app's notes and the message as its first task (`POST /api/agents`).
3. `HerdrClient.reply` follows the turn on the bridge's event stream (`GET /api/agents/{address}/{created_ms}/events`). When the stream cannot be opened or keeps breaking, it polls the saved rows and the reply so far instead.
4. The reply is final when the agent's own hook has saved it on the bridge.

Every request carries the server's access token as a bearer token, and the app's version and API level (`X-SwarmHub-App`, `X-SwarmHub-Api`). The bridge listens on loopback only and refuses a request whose `Host` is not `127.0.0.1:<port>` or `localhost:<port>`, so a remote server is reached through a forward of the same port number.

A message is cut to what the bridge accepts: plain text, up to 16 KB for a first task including the bot's instructions.

### Chat commands and goals

Type `/` at the start of a message or enter `/commands` to see the command list. Click a command, or highlight it with the arrow keys and press Tab or Return to insert it. Escape closes the list. Send the edited draft to run the command.

In a writable workspace bot chat, `/goal <objective>` starts a goal. Its panel shows the objective and the latest result. Use `/goal status` to check it and `/goal stop` or **Stop goal** to cancel. SwarmHub schedules one step at a time on that chat’s normal connection. Each finished step reports progress, completion evidence, a blocker, or a failure. Two consecutive steps without new progress pause the goal. Answer any outstanding question or workspace approval, then choose **Resume**.

The Mac saves the goal with the chat. On relaunch, a queued step can run when a turn slot opens. An iteration that may already have reached the workspace waits for you to check its result.

## Files on disk

The app keeps its data in `~/Library/Application Support/AgentApp/`:

| File or folder | Contents |
| --- | --- |
| `store.json` | Bots, groups and chats. |
| `runtime.sqlite` | The index of saved documents and the queue of messages waiting to be sent. |
| `attachments/` | Attached images. |
| `artifacts/` | Saved documents. |
| `grok-history/` | Read-only history imported from Grok Bot, one file per bot or group. Beside a bot's file, `<id>.handoff.json` holds the summary of its older part once one was made, and `<id>.handoff-state.json` what the app remembers about handing the history to the bot's agent (which agent has read it, a failure); both are removed with the history. |

If SwarmHub cannot open `store.json`, it moves the complete file aside as `store.json.corrupt-<time>` and offers the newest readable backup, if one is available.

The server list, each bot's server, template and model, "About you", and other preferences are in the app's `UserDefaults`. Access tokens are in the Keychain. For an SSH server the app saves the path of the key file, never the key.

## Environment

| Variable | Effect |
| --- | --- |
| `SWARMHUB_HERDR_TOKEN` | Access token for the first server, used only when the Keychain has none. For development launches. |
| `SWARMHUB_DISABLE_UPDATES=1` | Turns the app's updater off for this launch. A bare executable, a test run, a snapshot, a UI smoke run and a benchmark never look for updates. |
| `SWARMHUB_WORKSPACE_FEED` | Another place for the app to read the bridge's releases from when it hands one to a server: `https`, or `http` on this Mac's loopback. The signature is checked all the same. |
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
| `--render-setup <dir> [--light] [--only <prefix>]` | Renders the setup steps, Settings pages, the states of Software Update, chats and helper views from a synthetic store with sample content, dark unless `--light` is given; `--only` keeps the screens whose file name starts with the prefix. No network, no Keychain. It refuses a folder inside the repository. The screens in the README and the guide (`docs/screenshots`) come from it. |

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
| Trailing options | `<!-- choices -->` on its own line, followed by a numbered list that ends the message. | Choosing an option sends it as your reply. |
| Plain-text choices | A direct choice cue followed by a trailing numbered or lettered option list, or a clear yes/no question at the end of a reply. | The text stays visible. The buttons send the option's number or letter, Yes or No, or Both when explicitly offered. |
| Draft review | A fenced block with info string `draft`, `email`, or `message`. Start with optional `channel:` (also `via:`), `to:`, and `subject:` lines, followed by a blank line and the exact body. The `email` fence defaults to the Email channel. | **Edit** opens the recipient, email subject, and body inline. **Done editing** shows a preview, **Reset** restores the original, and **Copy** copies the current draft. **Send** tells the bot "Send it" for the original or gives it the exact revised draft to send. |
| Link pills | A bare `http(s)://` URL in prose. | A pill per link under the paragraph. |
| Image | `![alt](https://…)` or `![alt](data:image/…)`. | Shown inline. |

Use **Other** to write your own answer. Unanswered Yes/No questions on finished replies stay available when you return to a chat. Answering an older card quotes the question and sends the reply to its author. Other choices are active only on the latest finished reply.

When asking for approval before sending an email or outbound message, Herdr bots use a `draft` fence. The `channel:` line can name a service such as Email, WhatsApp, or Slack. The bot handles delivery after you click **Send**.

A fenced block with info string `swarmhub` is how a bot's agent asks the app for something: a new bot (`create_bot`, `request_bot`, `decline_bot`), a message to another bot (`message_bot`), an addition to "About you" (`about_you`), or another AI and model for several bots (`set_model`, from the main bot only). The chat never draws the block. It shows one plain line under the reply, such as "Suggested a new bot: Legal"; **Copy original** in that line's context menu copies the block. The blocks are described in [Architecture](architecture.md#bots-the-main-bot-and-helpers).

## Other code in this repository

- `HerdrWorkspace/`: the bridge and browser workspace, in Rust. Build and test instructions are in its README; how it updates itself is in [Updates](updates.md).
- `Apps/iOS-seed`: starting material for a future iPhone app (two SwiftUI source files, the app icon, screen drawings). It is not an app and nothing builds it; its [README](../Apps/iOS-seed/README.md) says what a phone app needs first.
- `scripts/export-grokbot.py` and the other Grok Bot export tools, with their tests (`scripts/test_*.py`). `bash Tests/Scripts/pysuites.sh <worktree> <log dir>` runs every Python test in `scripts/`.

## Credits

Bot avatars use BotAvatarsKit by Jakub Antalik (Libraries.dev), MIT. See [Third-party notices](../THIRD-PARTY-NOTICES.md).
