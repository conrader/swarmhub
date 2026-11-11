# SwarmHub features

What SwarmHub does today, and what is still being built. [Back to the overview](../README.md).

[Conversations](#conversations) · [Routines](#routines-goals-and-heartbeat) · [Agents](#your-agents) · [Connected apps and voice](#connected-apps-and-voice) · [Approvals](#approvals) · [Secure key sheet](#secure-key-sheet) · [Draft Send](#draft-cards-and-draft-send) · [Hermes and OpenClaw](#hermes-and-openclaw) · [Platforms](#platforms-and-updates)

Status checked from local documentation and current main `349db4c` on 2026-11-11:

- **Released** means recorded in local release history. Earlier features default
  to the 0.5.6 baseline unless a version is named; the release record now extends
  through **0.6.8**, matching `Resources/Info.plist`. Remote publication and the
  user's installed build are unverified.
- **Present in source** means implemented in this checkout, without asserting
  release or deployment. Main contains merged #35–#56 plus reviewed fixround3
  #58 (`510c5b3`) and iOS fix #59 (`349db4c`). The jobroute Mac worker stays
  disabled pending its isolated pilot.
- **Live verified** requires dated evidence from the actual server or Mac. No live
  checks or Mac builds were run for this docs update; historical test results
  below do not establish current native acceptance.

See [release history](CHANGELOG.md), [stack readiness](releases/stack-merge-readiness.md)
and the [roadmap and limits](ROADMAP-AND-LIMITS.md) for outstanding gates.

## Recent release record: 0.6.0–0.6.8

The [changelog](CHANGELOG.md) retains the per-release details and original skill
pins. Among the later changes are default connector restrictions (0.6.4),
webhooks and routine suggestions (0.6.5), timezone handling and disabled off-app
alerts (0.6.6), isolated skill-install sessions and overflow recovery (0.6.7),
and network/skill-install recovery plus steering during replies (0.6.8).
Count-based loops can still be handed to the box; goals and `--until` loops stay
in the app. Releases through 0.6.8 omit the signed embedded baseline pending the
key ceremony. Coding **1.3.16** and messages **1.4.16** are source-tip versions;
they do not replace older pins in release history.

Which features are available also depends on what your connected server supports. See the [Hermes versions SwarmHub works with](hermes-versions.md).

## Conversations

**Released**

- **Chat and threads:** streaming replies, separate Thinking / Typing / Working states, threaded conversations and Stop.
- **Corrections while an agent answers (0.6.8):** text steers the running turn when supported. Without steer, during installs or with attachments, it waits for the turn to end. A late Hermes 409 sends it next automatically; after the user's Stop it is offered instead of automatically sent.
- **Group chats:** several agents in one conversation. Use `@Name` to choose who answers; otherwise every member answers in turn.
- **Bot-to-bot messages:** agents can message each other with the bundled `bot-msg` skill script. The conversation shows who the message is for and when it arrives.
- **Images and files:** share images, text files, PDFs and Word/RTF documents. They are read on your Mac, with on-device OCR for scans. Chat images and links are collected in Media.
- **Reply recovery:** every reply says whether it finished, is incomplete or was not sent. A cut-off reply can recover the history available on your server, and Retry checks the server before sending anything again ([how it works](reference.md#never-losing-a-reply)).
- **Sidebar and shortcuts:** each chat shows its latest message or your unsent draft. The Navigate and Chat menus have keyboard shortcuts (Help → Keyboard Shortcuts), and ⌘K opens a quick switcher.
- **Sample agents:** before you connect a box, "Look around with sample agents" shows five labelled sample agents.

**Released in 0.5.7**

- **Pick up where you left off:** chats, groups and threads remember your reading position across restarts. **Jump to latest** shows how many new messages arrived below; incoming messages do not pull you away from older ones.
- **Folded technical rows:** app requests and results, bot-to-bot messages and skill-loading text appear as compact summaries. Unfold a row to read the original; previews and notifications use the summary too.
- **Clearer recovery after a restart:** if a queued message may already have been sent, SwarmHub keeps its text and warns you to refresh server history before sending again. It does not automatically replay that uncertain send. Retry requires a successful, sufficiently complete history check; this still cannot guarantee that remote work will never be duplicated.

**Present in source**

- **Held and priority delivery between agents:** a message from one agent to another waits for the recipient's next turn, and the chat says so ("Held for X's next turn"). `--priority` delivers it at once.
- **Completion wakes:** an agent is woken when a coding job it asked for finishes, and this survives an app restart.
- **Quiet replies:** `NO_REPLY` now counts as a quiet reply, like `[SILENT]`. A quiet reply to another agent no longer wakes that agent.

## Routines, goals and heartbeat

**Released**

- **Routines:** schedule recurring tasks for an agent and get the results in its chat.
- **Heartbeat:** a recurring check-in for each Hermes agent, set in Settings → Heartbeat. Each agent gets one Hermes routine that answers in its chat.
- **Quiet routine runs:** an agent can answer `[SILENT]` when nothing needs you. That reply is not shown, counted as unread or notified, and the Routines tab lists the run as "ok · silent".
- **Goals and loops:** a chat can hold a standing goal or a loop that SwarmHub drives itself. The turns SwarmHub starts on its own are labelled ("Woken by: goal"). The code is in 0.5.6, but these docs did not describe it before this page.

**Released in 0.5.9**

- **Heartbeat awareness:** once routines have loaded, Hermes agents are told which routine is their heartbeat, its schedule and next run or paused state, and where you can change it. The manager skill explains how to change that existing routine.
- **Keep schedule changes made on the box:** Settings → Heartbeat shows **changed on the box** and offers **Use the box's schedule** or **Put mine back**, instead of silently overwriting the change.

**Present in source**

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

**Present in source**

- **Sandboxed checks for coding jobs:** the bundled coding skill (`swarmhub-coding` 1.3.16) runs a job's test or build command in a sandbox. Only the job's workspace and a private temporary folder are writable, the environment is cleaned, there is no network, and the repository's git metadata is read-only. The recorded Linux simulation run was not fully green. Earlier records report a passing Swift build and automated tests on a Mac, but those results do not establish acceptance of the separate native sandbox and real coding-tool smoke checks.

## Connected apps and voice

**Released in 0.5.8**

- **Fewer approval prompts for connected apps:** actions clearly classified as read-only run without a card and show a folded result. Writes, uncertain actions and reads whose arguments could carry data out still ask you.
- **App errors reach the agent:** connected-app failures are explained and returned to the agent so it can continue the task; a `/goal` can survive an app failure. Diagnostic logs record the failure's shape without credentials.

**Released in 0.5.9**

- **Recognizable account names:** connected accounts use their own email, username or workspace identity when available, including Calendar, Drive, Slack and Notion. Unnamed accounts are checked again on refresh; names you set with **Rename…** are preserved. A numbered fallback remains when no identity is available.
- **App requests get an answer:** requests using an old turn marker get a correction with a bounded retry; unknown tools return an error asking the agent to search first. A request left unrun is folded with **This app request was not run**. A JSON object followed only by stray closing braces or brackets can still be read.
- **Readable live-voice failures:** the voice window identifies the failing step, such as microphone access, the ChatGPT account or an audio device. The error stays visible with **Copy details** and **Dismiss**; denied microphone access offers a link to System Settings. Copied diagnostics redact sensitive details.

Connected apps require their service configuration and connected accounts. The release plan still leaves the live voice check outstanding; the shipped error handling does not establish successful live-voice acceptance.

## Approvals

**Released**

- **Approve or decline** an agent's requests, and set a policy per agent: always ask, rules, or a reviewer agent. Decisions are written to a local audit log ([details](reference.md)).
- **Reviewer bots** can review specific kinds of request, or every bot's requests. Replies in group chats do not trigger reviews yet.
- **OpenClaw approvals:** requests from runs that SwarmHub started appear in SwarmHub. Requests from runs SwarmHub did not start always ask you.

**Released in 0.5.7:** automatic approvals use a narrower command-and-option allowlist. Unknown commands and mutating actions ask you; Git auto-approval is restricted to status forms. This is a command filter, not a sandbox.

**Present in source: managed approvals**

Actions that an agent queues through SwarmHub's runtime (coding, messages to other agents, reads, outbound messages, provisioning, money, production and secrets) appear as an approval card in the chat. The card is built from the runtime's own record of the action, not from the agent's description of it. It stays until a receipt from the runtime confirms your decision. If the answer is lost, the card stays and your original choice is locked in.

- **Agents on this Mac:** SwarmHub decides through the runtime's local `swarmctl` control command.
- **Agents on a remote box:** SwarmHub uses the agent's existing HTTPS connection and key. Each decision is signed, bound to that exact action, host and runtime, and valid for 60 seconds. Redirects and plain HTTP are refused.
  - The remote side also needs a small control service and a reverse-proxy route on the box (instructions are in the `swarmhub-messages` skill, version 1.4.16 at this source tip). Installing the skill does not set them up.
  - **Live status unverified:** the earlier feature review did not establish real-box deployment or the TLS/Keychain path; this offline review does not close that gate.

Earlier job records report Linux approval-service tests and Mac Swift tests, including `ManagedRemoteControlTests`. They are not a new run at this tip. Native local/remote approval cards and the real TLS/Keychain path still need acceptance evidence. Device-signed approval support is also present in source; see the [device-approval contract](update-service/DEVICE-APPROVALS.md). Current enrollment and deployment are unverified.

## Secure key sheet

**Present in source**

When an agent needs a key, it can ask for one, and SwarmHub opens a sheet: "*Agent* asks for a secret: *name*". You paste the key into a hidden field and press **Save and send the path**.

- The key goes into a file on this Mac that only your account can read (mode 0600, under `~/.hermes/swarmhub/secrets/`).
- The agent receives the file path, never the value. The chat shows only "Secret path for *name*". The agent can still read the file, because it runs as your account.
- The file is local: an agent on another host needs a separate way to receive keys there.
- The sheet appears only when an agent asks; you cannot open it yourself. Keys you enter in Settings are stored in the macOS Keychain as before.

Earlier records report a passing Swift build and automated tests on a Mac; this tip was not built for the docs review. The native key-sheet interaction has not yet been hand-tested on a Mac.

## Draft cards and Draft Send

**Released:** an agent can show a draft (for example, a message) as a card, and you can answer cards from the chat. In releases 0.5.6 through 0.5.9, **Send** on a draft card tells the agent "Send it".

**Present in source:** **Send** ties the exact draft to a managed outbound record that goes through [managed approvals](#approvals). This works for Hermes agents that have the `swarmhub-messages` skill installed. **Draft Send does not send anything yet.** Every outbound record is marked as a test record: it is logged but never delivered. The Swift code builds and its automated tests pass on a Mac; the native Draft Send interaction has not yet been hand-tested on a Mac.

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
