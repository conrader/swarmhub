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

- **Conversations:** streaming chat, threads, group chats with `@mentions`, images and files; saved reading positions and folded technical rows (0.5.7).
- **Routines:** recurring tasks, heartbeats and standing goals, with results in the agent's chat.
- **Your agents:** overview, models per agent, coding agents, agents that manage other agents, and import from Grok Bot.
- **Approvals:** approve or decline requests, with a policy per agent and reviewer bots.
- **Connected apps and voice:** fewer prompts for read-only app actions (0.5.8), recognizable account names and clearer live-voice errors (0.5.9).
- **Hermes and OpenClaw:** Hermes 0.20.5, 0.21.7 and 0.22.0. OpenClaw connects through its Gateway but has not yet been checked against a real Gateway.

In development, not released: managed approvals for agents on this Mac and on remote boxes (the remote service is not deployed yet), a secure key sheet that gives an agent a file path instead of the key, and Draft Send (it records drafts but does not send them yet).

The development Swift code builds and its automated tests pass on a Mac; these native UI flows have not yet been hand-tested. The full feature page covers releases through 0.5.9, though this development branch does not contain the 0.5.7–0.5.9 code changes.

**[All features, with what is released and what is in development →](docs/FEATURES.md)**

Available features depend on what your connected server supports. See the [Hermes versions SwarmHub works with](docs/hermes-versions.md).

## Try SwarmHub

In development for **macOS, Windows, Linux, iOS, and Android**. You can build the macOS prototype now; Windows and Linux versions are planned. The **iOS and Android apps are in development**; the first native iOS foundation is available to build, and Android is at the planning stage.

[iOS specsheet and screen designs →](docs/ios/README.md)

[Build the native iOS foundation →](Apps/iOS/README.md)

[Download the latest macOS build →](https://github.com/conrader/swarmhub/releases/latest) · [Get started →](docs/guide.md#get-started)

Installed builds update themselves through Sparkle: signed updates, checked once a day, installed now or when you quit (Settings → Check for Updates…; automatic download is in Settings → Advanced → About).

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

### Team coordination (development branch)

App-mediated peer handoffs, directed group work, recovery, task permissions and shared context are implemented on `codex/swarmhub-team-coordination`. [Usage and boundaries](docs/team-coordination.md). New work waits when SwarmHub cannot dispatch; no additional server runtime or Hermes configuration is required.
