# SwarmHub

<picture>
  <source media="(max-width: 600px)" srcset="docs/readme/hero-mobile.svg">
  <img src="docs/readme/hero.svg" alt="SwarmHub — your agents, one place to work." width="1280">
</picture>

A desktop interface for your **Hermes** and **OpenClaw** agents. Keep conversations, recurring tasks, and approvals together in one place.

Hermes is supported now; OpenClaw integration is planned.

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
- **Agents that manage agents:** ask your main agent to create a new agent, change an agent's instructions or avatar, or retire one. It asks you first, and the new agent appears in the sidebar with its own key. Works with stock Hermes; nothing is installed on your server.
- **Import from Grok Bot:** bring your Grok bots, their avatars and their history into SwarmHub (sidebar + → Import from Grok Bot…). Read-only; the full history needs one macOS Keychain prompt for Grok Bot's sign-in, which stays in memory and is never saved. It uses Grok Bot's private interface, so it can stop working when Grok changes it; recent messages from this Mac always import without it.
- **Sidebar and shortcuts:** every chat shows its latest message or your unsent draft; Navigate and Chat menus with keyboard shortcuts (Help → Keyboard Shortcuts).

Available features depend on what your connected server supports. See the [Hermes versions SwarmHub works with](docs/hermes-versions.md).

## Try SwarmHub

In development for **macOS, Windows, Linux, iOS, and Android**. You can build the macOS prototype now; Windows and Linux versions are planned. The **iOS and Android apps are in development**; the first native iOS foundation is available to build, and Android is at the planning stage.

[iOS specsheet and screen designs →](docs/ios/README.md)

[Build the native iOS foundation →](Apps/iOS/README.md)

[Download the latest macOS build →](https://github.com/conrader/swarmhub/releases/latest) · [Get started →](docs/guide.md#get-started)

Installed builds update themselves (signed updates, checked daily; Settings → Updates).

[How it works](docs/guide.md#how-it-works) · [Technical reference](docs/reference.md) · [Roadmap](PLAN.md)

## Credits

Bot avatars use [BotAvatarsKit](https://github.com/Jakubantalik/Libraries.dev/tree/a27566557b4def79bcdcedc71858c0fb28020b6d/packages/bot-avatars/ports/ios/BotAvatarsKit) by **Jakub Antalik (Libraries.dev)**, licensed under [MIT](Vendor/BotAvatarsKit/LICENSE).

[Third-party notices](THIRD-PARTY-NOTICES.md) · [Project license](LICENSE)
