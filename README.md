# SwarmHub

<picture>
  <source media="(max-width: 600px)" srcset="docs/readme/hero-mobile.svg">
  <img src="docs/readme/hero.svg" alt="SwarmHub — your agents, all together." width="1280">
</picture>

A desktop interface for your **Hermes** and **OpenClaw** agents. Keep conversations, recurring tasks, and approvals together in one place.

Hermes is supported; OpenClaw agents connect through their Gateway (built against OpenClaw 2026.10.3's published protocol and a test Gateway; first contact with a real Gateway is still to be checked).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/readme/swarmhub-light.png">
    <img src="docs/readme/swarmhub-dark.png" alt="Current SwarmHub interface with bot marks, chat previews, a group conversation, a draft card, and the agent Overview." width="1440">
  </picture>
  <br>
  <sub>Current macOS interface · demo content.</sub>
</p>

## Benefits

- Keep agent conversations and recurring work in one place.
- Spend less time repeating tasks by scheduling routines.
- Stay in control by reviewing requested actions.
- Use your own agents, server, and model choices.

## Features

- **Chat and threads:** streaming replies, threaded conversations, and stop controls.
- **Group chats:** multiple agents in one conversation, with `@mentions` to choose who responds.
- **Images and files:** share images, text files, PDFs and Word/RTF documents (read on your Mac, with on-device OCR for scans); find chat images and links in Media.
- **Routines:** schedule recurring tasks and receive their results in chat.
- **Agent overview:** see skills, tools, and available models.
- **Models per agent:** configure conversation and coding choices separately for each agent, such as Codex for conversation and Claude Code for coding. Conversation settings are available now; coding settings are planned.
- **Approvals:** approve or decline requests and set policies for each agent.
- **OpenClaw agents:** connect a Gateway from the setup window, or add one in Settings → Advanced → Servers and keys → OpenClaw (address and token; an SSH tunnel pairs at once, other networks need `openclaw devices approve`), then Add bots: streaming chat, Stop, steer, images, threads, history and the agent's approval requests. A paired Mac can read and write the Gateway's sessions; an agent that may run tools can run commands on the Gateway host. Approvals from runs SwarmHub did not start always ask you. [Details](docs/openclaw-integration.md).
- **Agents that manage agents:** ask your main agent to create a new agent, change an agent's instructions or avatar, change your agents' model, or retire one. It asks you first, and the new agent appears in the sidebar with its own key. Works with stock Hermes; Hermes itself is never changed. An OpenClaw agent can be the manager too: mark it "Can manage other bots" and it uses the stock `openclaw agents` commands on its Gateway host (the host must allow its `exec` tool, and you approve each command), and the new agent appears in the sidebar without any key; model changes and SwarmHub skills are Hermes-only for now.

  SwarmHub writes and versions its own skills (instructions such as "how to manage bots" and "how to change every bot's model") and installs them into an agent's own profile as ordinary Hermes skill files, the same thing you could install by hand, so the agent follows them instead of improvising. When an agent's copy is missing or older than SwarmHub's, its chat shows "SwarmHub's instructions for <agent> need installing" with **Install** (your press is the yes; the main agent writes the file) and **Not now**; the agent's settings → Advanced → SwarmHub skills lists each skill with its version. Once installed, management requests send a one-line pointer to the skill instead of the full text. While an agent works, its reply shows what it is doing ("Running a command · step 3 · 1 m 12 s"), and afterwards a folded "12 steps · 4 m 52 s" row opens to the list.
- **Import from Grok Bot:** bring your Grok bots, their avatars and their history into SwarmHub (sidebar + → Import from Grok Bot…). Read-only; the full history needs one macOS Keychain prompt for Grok Bot's sign-in, which stays in memory and is never saved. It uses Grok Bot's private interface, so it can stop working when Grok changes it; recent messages from this Mac always import without it.
- **No reply is lost:** every reply says whether it finished, is incomplete or was not sent; cut replies complete themselves from your server, and Retry checks the server before it sends anything ([how it works](docs/reference.md#never-losing-a-reply)).
- **Sidebar and shortcuts:** every chat shows its latest message or your unsent draft; Navigate and Chat menus with keyboard shortcuts (Help → Keyboard Shortcuts).

Available features depend on what your connected server supports. See the [Hermes versions SwarmHub works with](docs/hermes-versions.md).

## Try SwarmHub

In development for **macOS, Windows, Linux, iOS, and Android**. You can build the macOS prototype now; Windows and Linux versions are planned. The **iOS and Android apps are in development**; the first native iOS foundation is available to build, and Android is at the planning stage.

[iOS specsheet and screen designs →](docs/ios/README.md)

[Build the native iOS foundation →](Apps/iOS/README.md)

[Download the latest macOS build →](https://github.com/conrader/swarmhub/releases/latest) · [Get started →](docs/guide.md#get-started)

Installed builds update themselves (signed updates, checked daily; Settings → Updates).

The setup window (first run, or Settings → Change connection…) connects a Hermes box or an OpenClaw Gateway: pick OpenClaw, Test, approve this Mac if asked, and choose its agents, without opening Settings.

[How it works](docs/guide.md#how-it-works) · [Technical reference](docs/reference.md) · [Roadmap](PLAN.md)

## Mobile apps

The **iOS and Android apps are in development**. These screenshots show the first native iOS build with sample content. Android is at the planning stage.

<picture>
  <source media="(prefers-color-scheme: light)" srcset="docs/ios/screenshots/mobile-light.png">
  <img src="docs/ios/screenshots/mobile-dark.png" alt="Actual native SwarmHub iOS app: Chats, Conversation, Approvals and Settings, shown in an iPhone simulator with sample content." width="1480">
</picture>

[Individual screenshots and capture details](docs/ios/screenshots/SCREENSHOTS.md) · [Build the iOS app](Apps/iOS/README.md) · [Full feature specification and drawings](docs/ios/README.md)

## Credits

Bot avatars use [BotAvatarsKit](https://github.com/Jakubantalik/Libraries.dev/tree/a27566557b4def79bcdcedc71858c0fb28020b6d/packages/bot-avatars/ports/ios/BotAvatarsKit) by **Jakub Antalik (Libraries.dev)**, licensed under [MIT](Vendor/BotAvatarsKit/LICENSE).

[Third-party notices](THIRD-PARTY-NOTICES.md) · [Project license](LICENSE)
