# SwarmHub

<picture>
  <source media="(max-width: 600px)" srcset="docs/readme/hero-mobile.svg">
  <img src="docs/readme/hero.svg" alt="SwarmHub — your agents, all together." width="1280">
</picture>

SwarmHub is a native Mac app for working with a team of bots. Each bot is a real agent program, such as Claude Code or Codex, that runs in a terminal on a computer you choose: this Mac or your own server. You chat with a bot; it reads files, runs commands and writes code there, and you watch its reply and its tool steps as they happen.

The terminals are run by [Herdr Core](https://github.com/herdrdev/herdr-core), a separate open-source project. SwarmHub adds two things: the Mac app in this repository, and a small service that runs beside Herdr Core, the SwarmHub bridge (`HerdrWorkspace/`, the `swarmhub-herdr` binary). SwarmHub calls no model itself. Each agent program uses its own sign-in.

This is early software. What it does not do is listed under [Status](#status) and in [Limits](docs/ROADMAP-AND-LIMITS.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/chat-main-bot.png">
    <img src="docs/screenshots/light/chat-main-bot.png" alt="The main bot's chat: another bot's requests for new bots, passed on by SwarmHub, and the bots waiting above the message box for Create or Not now." width="760">
  </picture>
</p>
<p align="center"><sub>The main bot's chat. Every screen on this page is rendered by the app itself with sample content.</sub></p>

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/overview-dark.svg">
  <img src="docs/diagrams/overview-light.svg" alt="The Mac app talks to the SwarmHub bridge on the Herdr server; the bridge talks to Herdr Core, which runs the agent programs; the agents report back through hooks." width="1080">
</picture>

1. **You write to a bot.** The Mac app sends the message to the bridge over HTTP, with the server's access key. The bridge answers on its own machine only, so a server is reached through an SSH port forward, which the app can open itself.
2. **The bridge hands it to Herdr Core,** which types it into the bot's agent: a terminal running Claude Code, Codex or another agent program. If the bot has no agent yet, one is started first, with the bot's instructions.
3. **The agent works.** Hooks that the bridge gave the agent program report each tool call and, for Codex and for Claude Code templates that turn it on, the reply so far. The app follows them on one events connection and shows the reply as it is written, with the tool calls as steps under it.
4. **The reply is saved** by the agent program's own Stop hook when the turn ends, and the bridge sends it to the app.

A message you send while the agent answers goes into the running answer (steer). **Stop** presses the agent's own interrupt key.

The full picture, with the message flow, the security boundaries and a map of the code, is in [Architecture](docs/architecture.md).

## What you can do

- **Choose where bots run.** This Mac, a server you reach over SSH, or a server by address and access key. The setup window tests the connection and says what is wrong when it fails.
- **Keep a team of bots.** A bot has a name, an avatar, instructions, an agent program and a model. The agent programs and models offered are the ones your server lists; the app names none of its own.
- **Let the main bot build the team.** Each server has one main bot, marked with a star. It creates other bots, at once or after asking you. Any other bot that wants a new bot asks the main bot.
- **Have bots write to each other.** A bot names another bot and writes to it; the app passes the message on and the answer back, and both chats show everything. Fixed limits stop two bots from going on by themselves.
- **Hand work to helpers.** A bot's agent can start short-lived helper agents for parts of its work. The server's settings decide which agent program and model each difficulty runs on; the agent cannot choose. Helpers show under the bot and open read-only.
- **Work on projects on other servers.** Add the servers your projects live on, name folders on them as projects, and choose for each bot which it may use.
- **Share skills.** A server's skill library ([skillshare](https://skillshare.runkids.cc)) is listed in the app, where each skill is switched on or off.
- **Also in the app:** group chats with `@Name`, attachments (documents are sent as text), dictation with your own deAPI key, import from Grok Bot, sample agents that answer locally, automatic updates.

Details: [Features](docs/FEATURES.md).

## Quick start

You need a Mac with macOS 14 or later, and Herdr Core with at least one agent program (Claude Code or Codex) on the computer where the bots should work.

1. **Start Herdr Core and the bridge** on that computer: [Run locally](HerdrWorkspace/README.md#run-locally). The Mac app does not install or start them.
2. **Build and start the app** from this checkout, on a Mac with Xcode:

   ```sh
   ./scripts/run.sh
   ```

3. **Follow the setup window.** It opens while there is no bot.

   | Step | What you do |
   | --- | --- |
   | Where | Choose this Mac, a server over SSH, or a server by address and access key. |
   | Connect | Press **Test**. Over SSH you give the server's name; the app opens the connection and reads the access key itself. |
   | Main bot | Give it a name, an avatar, an agent program and a model. |
   | More bots | Optional: a bot for each other agent program the server has. |
   | Projects | Optional: add a server your projects are on. |

   The window ends in the main bot's chat.

To look around without a server, choose **Look around with sample agents** in the setup window.

> [!NOTE]
> The packaged build on the [releases page](https://github.com/conrader/swarmhub/releases) (0.6.8) is the earlier version of the app, from before it moved to Herdr Core. It does not match this README. Until a new release is published, build from source.

More: the [guide](docs/guide.md).

## Screens

Rendered by the app (`AgentApp --render-setup`) with sample content. No real server, name or key appears in them.

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/setup-where.png">
        <img src="docs/screenshots/light/setup-where.png" alt="The setup window: where should your bots run?" width="400">
      </picture>
      <br><sub>The setup window: where bots run.</sub>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/setup-main-bot.png">
        <img src="docs/screenshots/light/setup-main-bot.png" alt="The setup window: the main bot, its AI and model." width="400">
      </picture>
      <br><sub>The main bot, its agent program and its model.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/helper-view.png">
        <img src="docs/screenshots/light/helper-view.png" alt="A helper agent, opened read-only: its task, steps, latest reply and terminal." width="400">
      </picture>
      <br><sub>A helper agent, opened read-only.</sub>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/projects.png">
        <img src="docs/screenshots/light/projects.png" alt="Settings: project servers and projects." width="400">
      </picture>
      <br><sub>Project servers and projects.</sub>
    </td>
  </tr>
</table>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark/chat-steps.png">
    <img src="docs/screenshots/light/chat-steps.png" alt="A chat while the agent works: the line under the reply names the running tool step." width="760">
  </picture>
</p>
<p align="center"><sub>While the agent works, the chat names the step it is on.</sub></p>

## Documentation

| | |
| --- | --- |
| [Guide](docs/guide.md) | Setup and everyday use. |
| [Architecture](docs/architecture.md) | The pieces, how a message travels, what is enforced in code, the security boundaries, where the code is. |
| [The bridge's manual](HerdrWorkspace/README.md) | Running the bridge, its HTTP API, agent templates, helpers, projects, the browser workspace. |
| [How bots communicate](docs/bot-communication.md) | The behaviour SwarmHub is being built towards. A specification: [what exists today](docs/architecture.md#communication-the-target-and-today). |
| [Approvals](docs/approvals.md) | A second specification, mostly not built yet. |
| [Features](docs/FEATURES.md) · [Limits](docs/ROADMAP-AND-LIMITS.md) | What the Mac app does, and what it does not. |
| [Technical reference](docs/reference.md) | Build, files on disk, command-line flags, card syntax. |
| [Changelog](docs/CHANGELOG.md) · [Automatic updates](docs/updates.md) | History; signing and release steps. |

## Status

- The Mac app is the only app. There is no iPhone, Windows, Linux or Android app. The bridge also serves a [browser workspace](HerdrWorkspace/README.md) to the same agents, with features the Mac app does not have (a Library, Pages, routines, approvals, connected files).
- The app does not install Herdr Core, the bridge or an agent program. "Get a ready-made server from us" in the setup window is a placeholder.
- All agents on a server run as one account. The per-bot choices (projects, helpers) are bookkeeping, not isolation: see [Trust and security](docs/architecture.md#trust-and-security).
- Bots pass messages to each other only while the Mac app runs, because the app does the passing on.
- Most of [How bots communicate](docs/bot-communication.md) (kinds of messages, time limits, initiative, planned check-ins) and of [Approvals](docs/approvals.md) is not built.
- An agent gets text only. An attached image stays in the chat.

## Repository

| Path | What it is |
| --- | --- |
| `Sources/AgentApp`, `Tests/AgentAppTests` | The Mac app (Swift, SwiftUI) and its tests (`swift test` on a Mac). |
| `HerdrWorkspace/` | The bridge and the browser workspace (Rust). |
| `scripts/` | Build, run, packaging and update scripts for the Mac app, and the Grok Bot export tools. |
| `Resources/` | The app's Info.plist, entitlements, icons and avatars. |
| `Vendor/BotAvatarsKit` | The vendored avatar library. |
| `docs/` | Guide, architecture, reference, feature list, limits, changelog; the diagrams and screens on this page. |
| `Apps/iOS-seed` | Starting material for a possible iPhone app. It is not an app and does not build; see its [README](Apps/iOS-seed/README.md). |

## Credits

Bot avatars use [BotAvatarsKit](https://github.com/Jakubantalik/Libraries.dev/tree/a27566557b4def79bcdcedc71858c0fb28020b6d/packages/bot-avatars/ports/ios/BotAvatarsKit) by **Jakub Antalik (Libraries.dev)**, licensed under [MIT](Vendor/BotAvatarsKit/LICENSE).

[Third-party notices](THIRD-PARTY-NOTICES.md) · [Project license](LICENSE)
