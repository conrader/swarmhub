# Limits

What the macOS app does not do today. Each item was checked against the code in `Sources/AgentApp`. There is no dated roadmap in this file.

## Setup

- On **This Mac** the app installs and starts the SwarmHub service and, when it is missing, Herdr Core ([This Mac](guide.md#this-mac)). On a server it does not: start both yourself there. The first install of the bridge on a server is by hand; after that the app updates it ([Updates](updates.md)).
- Bots from versions up to 0.6.8 do not carry over to 0.8. On first launch the app saves a copy of the old data beside it and removes them.
- The SwarmHub service is published for Macs (Apple silicon and Intel) and for x86_64 Linux servers. Setting up **This Mac** needs an AI program you have already installed and signed in to (Claude Code or Codex); the app installs none.
- Gemini CLI is in beta (checked with Gemini CLI 0.70.0): its reply arrives whole, permission questions are answered in its terminal, a refused step or a turn stopped in the terminal keeps the bot reading as busy until **Stop** or its next turn, and a sign-in that has run out is not detected. The full list is in the [bridge manual](../HerdrWorkspace/README.md#run-gemini-cli-beta).
- On This Mac, the app answers two first-time questions of the AI programs for you when you leave that switch on: Claude Code's question about the bots' folder (one entry in `~/.claude.json`) and Codex's review of the three commands the service gives it (told at each start, nothing written). This was checked with Claude Code 2.1.319 and Codex 0.169.0. A later version of either program may ask in another way; the setup window then shows the question with **Answer in Terminal**. Codex did not ask about the folder itself on the Mac this was tested on; where it does, you answer it once.
- An agent's graphical desktop (`run-desktop`) exists on Linux servers only. The service on a Mac says so.
- Port 8787 must be free on the Mac, or you choose another port in the setup window.
- "Get a ready-made server from us" is one line marked "Coming soon". It is planned: today it cannot be chosen, no server is created and nothing is charged.
- The bridge answers on its own machine's loopback only. A remote server is reached through an SSH port forward that uses the same port number on both ends, so two servers with the same bridge port cannot be connected at the same time. Give one a different `SWARMHUB_PORT`.
- SSH runs in batch mode. A key with a passphrase must already be in the agent, because the app cannot ask for it.

## Chat

- An agent receives text only. An attached image is kept in the chat and is not sent to the agent.
- Only the newest message is sent. The agent keeps its own conversation, so the app's copy of earlier messages is not replayed to a fresh agent.
- A first task, with the bot's instructions, is cut to what the bridge accepts (16 KB).
- A reply is saved by the agent's own hook when its turn ends. An agent that stops at a prompt in its terminal saves none; the app stops waiting after the agent has been quiet for a while. Choose **Answer here** in chat. Older bridges also support the external terminal option.
- Stop presses the agent's interrupt key. What the agent does with it is up to the agent program.

## Not in the Mac app

These exist in the browser workspace ([HerdrWorkspace/README.md](../HerdrWorkspace/README.md)) but not in the Mac app:

- workspace-wide approval history and remembered read rules,
- routines and webhooks,
- Library browsing, editing Pages, and snapshots,
- connected folders, Google Drive and GitHub,
- taking over an agent’s graphical desktop.

## Bots and messages between them

- The bridge delivers messages between registered bots and tracks handoffs while the Mac app is closed. Creating a new bot from a proposal still requires the Mac app.
- PR watches support public GitHub Checks. They end after the first observed failure, a closed PR, or seven days. [Bot communication](bot-communication.md)
- All agents on a server run as the same account. The projects a bot may use, and whether it is told about helpers, are not isolation ([Trust and security](architecture.md#trust-and-security)).
- "About you" is one text for all bots on all servers, at most 800 characters. Only a main bot suggests additions, and the first conversation's rules (one question per reply, no other work until asked) are instructions to the bot, not something the app enforces.

## Helpers

- The app shows helpers and edits the server's helper settings. It does not start, stop or message a helper; the bot's agent does.
- A bot's agent cannot choose a helper's model. The server's settings do.

## Updates

- An app run from source (a bare executable) does not update itself. Software Update still checks the servers.
- A server whose bridge is from before it could update itself, or is installed where it cannot write, is updated by hand ([First install on a server](updates.md#first-install-on-a-server)).
- Releases carry a bridge program for 64-bit Intel and AMD Linux servers and for Macs (Apple silicon and Intel). On another kind of machine, such as an ARM Linux server, build the bridge there.
- Going back after an update is offered only while the journal still has the layout the previous version knows.
- The app does not install Herdr Core. It starts Herdr's own updater and shows what it said.

## Voice

- The app has no voice features in 0.8: dictation and reading a reply aloud were removed for now.

## Import

- A bot imported from Grok Bot gets its old history as a read-only archive, and its agent reads it before its next reply (summarised when it is long). Messages written in SwarmHub after the import are not part of what a newly started agent is handed. A running agent is not told about lines a later import adds; its next agent is. A group's imported history is not handed to its members. **New conversation** does not start an imported bot with nothing while its handover is on: the new agent reads the history again. The copies of the history that a handover leaves on the server (in the bot's workspace folder, and for a summary in a folder of its own) are not removed by the app.
- A template import uses the name, title, description, instructions and avatar. The import report lists what else the template held and was left out.

## Other platforms

- There is no iPhone app. A phone cannot reach the bridge today: it answers only on the machine it runs on. `Apps/iOS-seed` keeps starting material for one ([README](../Apps/iOS-seed/README.md)).
- There is no Windows, Linux or Android app. The bridge's browser workspace runs wherever a browser can reach it.


## Outbound delivery

- Real Gmail, Slack and WhatsApp delivery stays off. The Gmail fixture exercises the send and Sent lookup contracts over a local executor channel. Email can be downloaded as an `.eml` for manual delivery.
- Real enablement requires an authorized sender, both send and Sent lookup capabilities, operator-approved credential provisioning and verification against the chosen provider. P0-07 also needs isolated OS accounts for the worker and executor. A production Vault executor, a bridge-signed grant verified by the worker over an authenticated channel and real Core stdin execution remain open.
