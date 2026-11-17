# Limits

What the macOS app does not do today. Each item was checked against the code in `Sources/AgentApp`. There is no dated roadmap in this file.

## Setup

- The app does not install or start Herdr Core or the bridge. Start both yourself on the machine where the bots work.
- The packaged build on GitHub (0.6.8) is the earlier version of the app. Until a newer release is published, the app described here is built from source.
- "Get a ready-made server from us" is a placeholder. No server is created and nothing is charged.
- The bridge answers on its own machine's loopback only. A remote server is reached through an SSH port forward that uses the same port number on both ends, so two servers with the same bridge port cannot be connected at the same time. Give one a different `SWARMHUB_PORT`.
- SSH runs in batch mode. A key with a passphrase must already be in the agent, because the app cannot ask for it.

## Chat

- An agent receives text only. An attached image is kept in the chat and is not sent to the agent.
- Only the newest message is sent. The agent keeps its own conversation, so the app's copy of earlier messages is not replayed to a fresh agent.
- A first task, with the bot's instructions, is cut to what the bridge accepts (16 KB).
- A reply is saved by the agent's own hook when its turn ends. An agent that stops at a prompt in its terminal saves none; the app stops waiting after the agent has been quiet for a while. Answer the prompt in the browser workspace or with `hc attach`.
- Stop presses the agent's interrupt key. What the agent does with it is up to the agent program.

## Not in the Mac app

These exist in the browser workspace ([HerdrWorkspace/README.md](../HerdrWorkspace/README.md)) but not in the Mac app:

- approvals of an agent's permission requests,
- routines and webhooks,
- the Library, Pages, snapshots and published files,
- connected folders, Google Drive and GitHub,
- taking over an agent's terminal or desktop.

## Bots and messages between them

- A bot is a record in the Mac app. Messages between bots and requests for new bots are passed on by the app, so nothing moves between bots while the app is closed.
- [How bots communicate](bot-communication.md) describes more than exists: there is one kind of message, no time limit on an answer, no hand-off of work, no planned check-ins, and no bot writes to you unprompted. [What exists today](architecture.md#communication-the-target-and-today).
- All agents on a server run as the same account. The projects a bot may use, and whether it is told about helpers, are not isolation ([Trust and security](architecture.md#trust-and-security)).

## Helpers

- The app reads helpers and edits the server's helper settings. It does not start, stop or message a helper; the bot's agent does.
- A bot's agent cannot choose a helper's model. The server's settings do.

## Voice

- Dictation needs your own deAPI API key and sends the recording to deAPI.
- A reply is read aloud with the Mac's built-in speech. There is no choice of voice or speed in the app.

## Import

- A bot imported from Grok Bot gets its old history as a read-only archive. The history is not sent to the bot's new agent.
- A template import uses the name, title, description, instructions and avatar. The import report lists what else the template held and was left out.

## Removed backends

- Older versions ran bots on two other backends, which are gone. Bots that ran on them are not loaded; the store is backed up first ([Features](FEATURES.md#stores-from-older-versions)).

## Other platforms

- There is no iPhone app. A phone cannot reach the bridge today: it answers only on the machine it runs on. `Apps/iOS-seed` keeps starting material for one ([README](../Apps/iOS-seed/README.md)).
- There is no Windows, Linux or Android app. The bridge's browser workspace runs wherever a browser can reach it.
