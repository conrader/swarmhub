# SwarmHub features

What SwarmHub does today, and what is still being built. [Back to the overview](../README.md).

[Conversations](#conversations) · [Routines](#routines-goals-and-heartbeat) · [Agents](#your-agents) · [Approvals](#approvals) · [Secure key sheet](#secure-key-sheet) · [Draft Send](#draft-cards-and-draft-send) · [Hermes and OpenClaw](#hermes-and-openclaw) · [Platforms](#platforms-and-updates)

Each feature carries one of these labels:

- **Released**: in SwarmHub 0.5.6, the version this page was checked against.
- **In development**: built on the development branch, not merged and not in any release. Unless a section says otherwise, the app side of this work has not yet been built or tested on a Mac.

This page describes the development line at `843024b`, which split from 0.5.6. Releases 0.5.7 to 0.5.9 were published later from `main`, and their changes are not covered here yet; see the [release notes](https://github.com/conrader/swarmhub/releases).

Which features are available also depends on what your connected server supports. See the [Hermes versions SwarmHub works with](hermes-versions.md).

## Conversations

**Released**

- **Chat and threads:** streaming replies, separate Thinking / Typing / Working states, threaded conversations and Stop.
- **Corrections while an agent answers:** type into the running reply ("Add to this answer…").
  - If the agent is running a step, your correction lands right after that step and the reply continues below it.
  - If the agent is only writing, SwarmHub stops the answer (what it wrote stays) and sends your correction as the next message.
  - If a correction does not get through, **Send as next message** sends it as a normal message once the answer ends.
- **Group chats:** several agents in one conversation. Use `@Name` to choose who answers; otherwise every member answers in turn.
- **Bot-to-bot messages:** agents can message each other with the bundled `bot-msg` skill script. The conversation shows who the message is for and when it arrives.
- **Images and files:** share images, text files, PDFs and Word/RTF documents. They are read on your Mac, with on-device OCR for scans. Chat images and links are collected in Media.
- **No reply is lost:** every reply says whether it finished, is incomplete or was not sent. A cut-off reply completes itself from your server, and Retry checks the server before sending anything again ([how it works](reference.md#never-losing-a-reply)).
- **Sidebar and shortcuts:** each chat shows its latest message or your unsent draft. The Navigate and Chat menus have keyboard shortcuts (Help → Keyboard Shortcuts), and ⌘K opens a quick switcher.
- **Sample agents:** before you connect a box, "Look around with sample agents" shows five labelled sample agents.

**In development**

- **Held and priority delivery between agents:** a message from one agent to another waits for the recipient's next turn, and the chat says so ("Held for X's next turn"). `--priority` delivers it at once.
- **Completion wakes:** an agent is woken when a coding job it asked for finishes, and this survives an app restart.
- **Quiet replies:** `NO_REPLY` now counts as a quiet reply, like `[SILENT]`. A quiet reply to another agent no longer wakes that agent.

## Routines, goals and heartbeat

**Released**

- **Routines:** schedule recurring tasks for an agent and get the results in its chat.
- **Heartbeat:** a recurring check-in for each Hermes agent, set in Settings → Heartbeat. Each agent gets one Hermes routine that answers in its chat.
- **Quiet routine runs:** an agent can answer `[SILENT]` when nothing needs you. That reply is not shown, counted as unread or notified, and the Routines tab lists the run as "ok · silent".
- **Goals and loops:** a chat can hold a standing goal or a loop that SwarmHub drives itself. The turns SwarmHub starts on its own are labelled ("Woken by: goal"). The code is in 0.5.6, but these docs did not describe it before this page.

**In development**

- **Goal evidence:** `/goal --coding` and `/goal --general` say what proof of "done" a goal needs. A plain `/goal` is classified from its wording. The mode is shown when the goal starts and in `/goal status`. A coding goal reported as done without a commit or a passing test is sent back for evidence a limited number of times, then marked blocked. Classifying a goal from its wording is a heuristic and can misjudge unusual phrasing.

## Your agents

**Released**

- **Agent overview:** skills, tools, available models, the agent's memory note, and the tasks it handed to sub-agents.
- **Models per agent:** pick a conversation model and a coding model for each agent from the models its server offers. **Code in thread** on a reply opens a thread that uses the coding model.
- **Coding agents:** agents can hand coding work to Claude Code or the Codex CLI.
- **Agents that manage agents:** ask your main agent to create, change or retire an agent, or to change models. It asks you first.
  - With Hermes, the new agent gets its own key, and Hermes itself is never modified.
  - An OpenClaw agent can be the manager too. It uses the stock `openclaw agents` commands on its Gateway host, and you approve each command. Model changes and SwarmHub skills are Hermes-only.
- **SwarmHub skills:** SwarmHub installs versioned instruction files into an agent's own profile as ordinary Hermes skills. The chat offers **Install** when an agent's copy is missing or out of date.
- **Import from Grok Bot:** bring your Grok bots, their avatars and their history into SwarmHub (read-only). Full history needs one Keychain prompt. The import uses Grok Bot's private interface, so it can break when Grok changes it.

**In development**

- **Sandboxed checks for coding jobs:** the bundled coding skill (`swarmhub-coding` 1.3.12) runs a job's test or build command in a sandbox. Only the job's workspace and a private temporary folder are writable, the environment is cleaned, there is no network, and the repository's git metadata is read-only. On Linux this has automated tests, but the full suite is not yet green on the test host. On macOS it has not been accepted: the latest Mac test runs were against earlier commits, and some of those failed.

## Approvals

**Released**

- **Approve or decline** an agent's requests, and set a policy per agent: always ask, rules, or a reviewer agent. Decisions are written to a local audit log ([details](reference.md)).
- **Reviewer bots** can review specific kinds of request, or every bot's requests. Replies in group chats do not trigger reviews yet.
- **OpenClaw approvals:** requests from runs that SwarmHub started appear in SwarmHub. Requests from runs SwarmHub did not start always ask you.

**In development: managed approvals**

Actions that an agent queues through SwarmHub's runtime (coding, messages to other agents, reads, outbound messages, provisioning, money, production and secrets) appear as an approval card in the chat. The card is built from the runtime's own record of the action, not from the agent's description of it. It stays until a receipt from the runtime confirms your decision. If the answer is lost, the card stays and your original choice is locked in.

- **Agents on this Mac:** SwarmHub decides through the runtime's local `swarmctl` control command.
- **Agents on a remote box:** SwarmHub uses the agent's existing HTTPS connection and key. Each decision is signed, bound to that exact action, host and runtime, and valid for 60 seconds. Redirects and plain HTTP are refused.
  - The remote side also needs a small control service and a reverse-proxy route on the box (instructions are in the `swarmhub-messages` skill, version 1.3.9 on this branch). Installing the skill does not set them up.
  - **Not deployed:** this service has not been run on a real box. The path through a real TLS connection and the Keychain is untested.

The approval service has automated tests on Linux. The app side (cards and remote signing) has not been built or tested on a Mac.

## Secure key sheet

**In development**

When an agent needs a key, it can ask for one, and SwarmHub opens a sheet: "*Agent* asks for a secret: *name*". You paste the key into a hidden field and press **Save and send the path**.

- The key goes into a file on this Mac that only your account can read (mode 0600, under `~/.hermes/swarmhub/secrets/`).
- The agent receives the file path, never the value. The chat shows only "Secret path for *name*". The agent can still read the file, because it runs as your account.
- The file is local: an agent on another host needs a separate way to receive keys there.
- The sheet appears only when an agent asks; you cannot open it yourself. Keys you enter in Settings are stored in the macOS Keychain as before.

The sheet has not yet been tested on a Mac.

## Draft cards and Draft Send

**Released:** an agent can show a draft (for example, a message) as a card, and you can answer cards from the chat. In 0.5.6, **Send** on a draft card tells the agent "Send it".

**In development:** **Send** ties the exact draft to a managed outbound record that goes through [managed approvals](#approvals). This works for Hermes agents that have the `swarmhub-messages` skill installed. **Draft Send does not send anything yet.** Every outbound record is marked as a test record: it is logged but never delivered. This path has not been exercised in the app on a Mac.

## Hermes and OpenClaw

- **Hermes (released):** each agent is a Hermes profile with its own key. Works with Hermes 0.20.5, 0.21.7 and 0.22.0; older versions are not supported ([version notes](hermes-versions.md)).
- **OpenClaw (released, not yet checked against a real Gateway):** connect a Gateway from the setup window or in Settings → Advanced → Servers and keys → OpenClaw, then add its agents. Supported: streaming chat, Stop, steer, images, threads, history and approval requests.
  - The integration was built against OpenClaw 2026.10.3's published protocol and tested only against a scripted test Gateway. No real Gateway has been contacted yet.
  - A paired Mac can read and write the Gateway's sessions, and an agent allowed to run tools can run commands on the Gateway host.
  - [Details](openclaw-integration.md).

## Platforms and updates

- **macOS (released):** a prototype you can [download](https://github.com/conrader/swarmhub/releases/latest) or [build](guide.md#get-started). Installed builds update themselves through Sparkle, with signed updates checked once a day.
- **iOS (in development):** a first native foundation you can build ([iOS app](../Apps/iOS/README.md), [specsheet](ios/README.md)).
- **Android:** planning stage.
- **Windows and Linux:** planned.
