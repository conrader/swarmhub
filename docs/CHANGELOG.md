# Changelog

## Unreleased

- **Gemini (beta)**: Google's Gemini CLI is a third program a bot can run on, next to Claude Code and Codex. It is listed last, is never chosen by default while another AI is installed, and says where you choose it what it cannot do yet: its reply arrives all at once, it asks for permission in its terminal, and a model change applies at the next start. Sign in by running `gemini` in Terminal first. Details and limits are in the [bridge manual](../HerdrWorkspace/README.md#run-gemini-cli-beta).
- Skills is a library. **Settings → Servers → Skills** and a bot's **Skills** tab say where the server's skillshare library stands and sync it with one button; **Open library** shows everything in it (skills, agents, MCP servers, plugins and hooks) grouped by what needs a sync, has an update, is in sync or is off, with a preview of each.
- Skills are installed from a repository address after a security check: the server downloads the repository, skillshare audits it, and only what passes is installed. A blocked skill shows what was found, can be handed to a bot to review, and is installed only after **Install anyway**. Skills and agents are updated and removed from the library too.
- The library's Git repository is pulled, pushed and synced both ways from the app, with a choice per file when both sides changed the same one. **Servers** shows skillshare on each server and updates it.
- A bot whose project holds a skillshare project of its own can show that project's library.
- The bridge's API is at level 2 for this (`/api/skillshare/library` and the routes beside it, in the [bridge manual](../HerdrWorkspace/README.md#manage-the-servers-skillshare-library)). An MCP server's secret values never leave the server. A server still at level 1 keeps the list of skill switches until it is updated.

## 0.8.8 (build 42)

- Bots imported from Grok Bot carry on: before a bot's next reply its agent reads the imported conversation (a summary of the older part, the recent part word for word, the full transcript to search). Long conversations are summarised once by the bot's own program. It applies to bots imported earlier, can be switched off per bot under the chat's Grok history header, and never holds a message back: if it cannot be handed over, the message is delivered and the chat says so.
- The bot list can be divided into named sections that fold and unfold (**+ → New Section…**, or **Move to Section** in a chat's menu); a section can be renamed, moved up or down and deleted, and deleting one only moves its chats to Unsectioned. **Pin** puts up to nine bots or groups at the top as big marks with their names under them. Folds, sections and pins are remembered; with none of them the list looks and behaves as before.
- Import from Grok Bot: a refusal or an unreadable answer from Grok no longer stops the import. It says what Grok said, imports the recent messages kept on this Mac, and remembers the stop for the next time. A stop inside one chat affects that chat only; too many requests pause instead of stopping; chats that only got recent messages are partial and stay under **Retry remaining**.
- The import sheet's steps are redrawn: the history choice as two large cards, the macOS prompt as three numbered steps, one line per chat while importing.
- The secret filter takes quoted, escaped and bold labels and whole quoted values, and no longer takes ordinary code such as `PWD=/path`. Saved history lines go through the current filter on every import.

## 0.8.7 (build 41)

- Setup now detects an installed Codex CLI on your Mac without opening Terminal or waiting for an update.
- Workspace 0.2.6 skips the optional Codex update prompt when SwarmHub starts a bot.

## 0.8.5 (build 39)

- The workspace time zone follows your Mac by default. You can also choose a fixed time zone in Settings.
- You can opt in to share your city and country. The Mac resolves approximate location locally, and bots can see your workspace time zone and the city you choose to share.
- Routines that follow the workspace time zone stay on local wall-clock time as the zone changes. Routines with an explicit time zone keep that zone.

Workspace 0.2.4 applies one-way database migration 62. Keep a pre-upgrade workspace backup if you need to return to 0.2.3.

## 0.8.4 (build 38)

Workspace 0.2.3 ships the Herdr fleet, jobs and approval changes.

- Staging parks record the exact action under review. Signed fleet policy scopes who can decide, a single claim prevents duplicate execution, and eligible parks require independent review with bounded repair attempts.
- Managed jobs check worker capabilities and resource limits, track start, stop and recovery, and return durable completion notices to the owning bot even when its session is busy or disconnected.
- Vault grants bind credential use to the approved job, command and worker. The Vault executor is fixture-only, and separate worker and executor OS accounts remain open (P0-07).
- Outbound email drafts pin the approved content, recipient and sender. Fixture delivery records and reconciles attempts. Outbound sending stays off pending live provider commissioning (P0-08).
- Fleet controls require signed fleet authority. Background completion retries persist across restarts, and idle managed-job polling stops.

## 0.8.2 (build 36)

- Retired Hermes and OpenClaw integrations are removed. Stores from older releases still load their Herdr bots and groups, with references to retired bots dropped.
- Workspace 0.2.2 adds the Vault for securely entering secrets from the Mac app or browser and approving credential use by managed agents.
- Vault approvals stay tied to the requesting session. Reusable approvals enforce their time and use limits, and Vault masks credential values in captured command output.

## 0.8.0 (build 34)

The first release on Herdr Core. Bots from earlier versions do not carry over; the app saves a copy of the old data and removes them on first launch.

- Bots run on Herdr Core. A bot is one agent on a Herdr server: an agent program such as Claude Code or Codex in a terminal there, reached through the SwarmHub bridge (`HerdrWorkspace/`, `swarmhub-herdr`). How the parts fit together is in [Architecture](architecture.md).
- A setup window that ends in the main bot's chat: where bots run (**This Mac**, or **A server** over SSH with the port forward opened by the app; a server by address and access key is under **Advanced**), a connection check that says what is wrong, the main bot, optional bots for the server's other agent programs.
- Replies show as they are written, with each tool call as a step. The app follows a turn on the bridge's event stream and polls when the stream cannot be used. Codex replies stream too.
- A message sent while an agent answers goes into the running answer (steer), by default. Stop presses the agent's own interrupt key.
- A bot's agent program and model are chosen from what its server lists. The app names no model of its own; a bot without a choice starts on the first model the server lists.
- Each server has one main bot, marked with a star. It creates bots, at once or after asking you; any other bot asks the main bot.
- Helper agents: a bot's agent can start helpers, the server's helper settings decide what each difficulty runs on, and helpers show under the bot and open read-only. The server stops a helper after its answer.
- Bots write to each other by name. The app passes the message and the answer on, both chats show them, and follow-ups are allowed within fixed limits (8 messages between two bots, 4 bots in a chain, 6 messages per bot in ten minutes).
- A server's skill library (skillshare) is listed in Settings and in a bot's Details, with a switch per skill.
- A bot's agent starts when its chat opens, so the first message does not wait for the agent program. The chat header says Starting or Ready, and a reply that has no text yet says what it is waiting for. **Keep _name_ ready** (a bot's Details, Model, Advanced) turns it off for one bot.
- A new app icon, "Crew": three faces, the main bot in front. On macOS 26 the icon follows the Mac's icon style.
- Documentation: an [architecture document](architecture.md) with four drawings (`docs/diagrams`), screens rendered by the app with sample content (`docs/screenshots`), and a README that describes the app as it is now.
- Project servers: add the servers your projects live on to a Herdr server (its public key to paste, the SSH address, the host's fingerprint to check and trust), name folders on them as projects, and choose for each bot which projects it may use. The setup window has an optional last step for it, and **Settings → Servers** a Projects part, with one card per project server and its projects inside.
- A new look for the setup window, a bot's Details and settings, the helper view and the Servers pane of Settings, after Apple's own onboarding and settings: large options, galleries of tiles, fields that stand on their own, settings with a heading and a sentence. No screen is a table of labels and values.
- A warm look taken from the app icon: cream surfaces in light and olive charcoal in dark, with a clay accent by default. Sage is a new accent, Graphite is still offered, and an accent you chose is kept. Each chat carries its bot's colour: a soft wash behind its name, its face and name above the first reply of each run, and the cards above the composer.
- Plain words and fewer choices, after an audit of every screen as a first-time reader sees it. The app says "bot" everywhere, "AI" for the agent program a bot runs on (by its short name: "Claude", "Codex"), and "helper"; it no longer says runtime, template or steer. Settings is one window with panes (General, Servers, Software Update, About) instead of a simple page with an Advanced part. What a bot runs on is chosen in one place, the Model tab of its Details, with **Start fresh**. The setup window offers two places, with the address route under **Advanced** and the ready-made server as one "Coming soon" line.
- What the app puts into a chat for a bot no longer looks like your own words: a request or message from another bot is a card with that bot's face, and what a reply asks the app for is one plain line ("Suggested a new bot: Legal") instead of a block of JSON.
- Messages between bots are folded to one row with the sender's face, name and first sentence, in that bot's colour; a click unfolds one. Long instructions in the cards above the message box fold the same way.
- The row of steps in a reply stands between paragraphs, never inside a word or a sentence.
- What is chosen can be seen: a picked answer to a bot's question, the AI and model tiles, setup options, the theme and accent pickers and the open chat in the sidebar are filled or washed with the accent and ticked, and switches and default buttons keep their colour in an inactive window. Contrast is checked in tests for the three accents in light and dark.
- On macOS 26 the message box, the cards above it, "Jump to latest" and the Settings button in the sidebar use Liquid Glass, and the chat scrolls beneath them. Older systems, Reduce Transparency and Increase Contrast keep the solid surfaces.
- An agent that waits at a question in its terminal shows the question in a card above the message box, with **Answer in Terminal** (or **Open in Browser** for a server added by address), an unread mark and a notification, once per question.
- Removing a bot ends its agent on the server. When the server cannot be reached the bot is still removed and its agent is ended the next time the app can.
- Voice is removed for now: dictation, reading a reply aloud, the Voice pane of Settings, and the microphone permission.
- The first conversation: a main bot that the setup window has just created says hello and asks a few short questions, each of which can be skipped. What it learns is offered above the composer and kept, only with your OK, as **About you** (Settings → General), a short text every bot reads. An earlier main bot offers the same once; **Get to know me** asks for it again.
- Software Update, a new pane in Settings: the app (through Sparkle, checked once a day without a window), and for each server the version of the bridge and of Herdr Core, with one button when something is behind. A server installs a signed release of the bridge itself, keeps its agents running through the restart, and goes back to the previous version when the new one does not start. One script makes a release, and an update can be rehearsed without credentials. See [Updates](updates.md).
- Documentation brought in line with the interface after these changes: the README, the guide, the feature list (checked item by item against the code), the architecture document, the reference and the limits.
- Herdr only: the Hermes and OpenClaw backends are removed, with every feature that only worked with them: profiles and keys on a Hermes box, the bot manager and SwarmHub skills, routines, heartbeats, webhooks, off-app alerts, reports, usage, approvals and device approvals, connected apps, the ChatGPT connection and live voice, threads, workflows and team coordination, goals and loops, the box updater, QA mode and UI acceptance mode, and the Computer tab. The app now runs bots only as agents on Herdr Core, through the SwarmHub bridge.
- A store written by an older version is first copied as it was to `store.json.before-herdr-only-<time>` beside it, once. Hermes and OpenClaw bots in it are then left out: the store is saved without them, and the app says once how many bots were removed and where the copy is. Bots on Herdr keep their name, avatar, instructions and chat.
- Scripts, tests, fixtures and documents that only served the removed backends are deleted. Entries below describe earlier versions as they were; some of the documents they link to no longer exist.
- The earlier iPhone app, the two Swift packages only it used, and the signed update-bundle tooling for servers of the removed backends are deleted. The Mac app's own updates (Sparkle) were not part of that tooling and stay. What an iPhone app for Herdr could reuse (two SwiftUI source files, the app icon, the screen drawings) is kept in `Apps/iOS-seed`, which is not an app and does not build.

## 0.6.8 (build 33)

- No "The network connection was lost." popups: transient network errors (-1005, -1001, -1004, -1009, dropped streams, and CFNetwork host, PAC and bridged URL errors) never open the Backend Error alert. A turn that never left the Mac is sent again by itself (1, 3, 8, 15 s) with "Reconnecting…" on its row; a dropped reply reconnects as before, now without a warning line per reconnect; what is left after the retries is one small line at the bottom of the window that clears when the box answers again.
- Skill installs: an install whose stream dropped or timed out is sent again in a fresh setup session (Hermes stops a native stream's run when its client disconnects, and installs only write files). A failure that was only the connection waits two minutes before Retry instead of the 15-minute backoff. Install problems are a line in the manager's chat, not an alert, and a network-interrupted install is a notice, not an error. A release build has the box fetch the skill files it ships unchanged (`scripts/`) from the build's own commit on GitHub, digest-checked before anything is written, so large skills such as swarmhub-messages (~290 KB) no longer depend on the model retyping them; SKILL.md and per-bot files still go inline. A session title another session already holds (`invalid_title`) is retried with a unique one instead of failing.
- Steer, don't interrupt: a message typed while a bot answers steers the running turn (Hermes `run_steer`, OpenClaw `queueMode: "steer"`) whatever it is doing; the old "stop the answer and send the correction" path is gone. Without steer, during an install, or with attachments, the message waits and goes when the turn ends. A steer the run can no longer take (Hermes 409 `run_not_accepting_steer` at the end of an answer) goes as the next message by itself; after the user's Stop it is offered, never sent by itself.
- swarmhub-messages 1.4.15 (existing bots update from 1.4.14): the webhook receiver and `webhook fire` accept `message` when `text` is missing or blank; a body `key` counts only when the `X-SwarmHub-Key` header is missing or empty; `webhook receiver install|status --port N` keeps an account-specific loopback port (8745 stays the default); deeply nested JSON gets a 400 JSON error.
- Developer only: `--e2e-live` self-test harness (hidden, off screen, deletes only its own self-test sessions before and after). Ops tooling (`ops/webhook-probe`, `ops/wake-enroll`) is in the repository, not in the app.
- Off-app alerts stay switched off (as in 0.6.6 and 0.6.7). Ships without the embedded baseline (P1b pending), like 0.6.0–0.6.7. Release text: [releases/v0.6.8.md](releases/v0.6.8.md).

## 0.6.7 (build 32)

- Installs in a throwaway session: installing or restoring a skill (one bot, all bots, an imported skill, adoption, key restore) runs in its own short-lived Hermes session, created for the turn and deleted after it, so a long manager conversation can no longer make an install fail, and the manager's main chat is never touched. An install that did not reach the box retries by itself (2 s, then 8 s) in a fresh session; Retry on a failed install, also after a relaunch, runs and checks the same way as the first send.
- Context overflow recovers by itself: when a chat's conversation is too long for the model, the app tries the same session once more (Hermes compacts at the start of a turn), then continues in a new session with the message resent; the transcript is kept and an inline note says what happened. A reply whose tool steps already ran is never resent.
- Store restore: when store.json is missing, unreadable or only the untouched seeded bot, the newest backup that loads is offered in a prompt ("Restore my N bots" / "Start fresh"); the current file is moved aside, never deleted.
- Friendly errors: Hermes' "/new or /compress" advice is no longer shown; when recovery runs out the chat gets a plain line.
- Off-app alerts stay switched off (as in 0.6.6). Ships without the embedded baseline (P1b pending), like 0.6.0–0.6.6. Release text: [releases/v0.6.7.md](releases/v0.6.7.md).

## 0.6.6 (build 31)

- Routine suggestions: the routine a yes asks for is converted to the box's time zone (read from its jobs' times, UTC when none say), at the offset of its next run, so DST and runs that cross midnight land on the time offered; the user still sees their own time. A routine the bot made on the converted schedule, or on the unconverted one a 0.6.5 lead asked for, counts as made, so the editor no longer invites a duplicate. The bot is asked for `deliver 'local'`.
- Daylight saving time: Hermes runs cron in one zone per profile (UTC on our boxes) with no zone per job, so the app moves a routine its suggestion made when the clocks' difference changes (a Warsaw 09:00 routine is 07:00 UTC in summer, 08:00 in winter), once the next run is past the change; a routine changed since is left alone. The lead tells the bot, and the routine editor names the box's zone and says it does not change for daylight saving time. While the Mac is off across a change, runs until the app next reads the jobs can be an hour off.
- Off-app alerts are switched off for now (swarmhub-messages 1.4.14): Settings shows no alerts section, the app sends nothing to a box about alerts and installs no service, and a box a 0.6.5 app turned alerts on for sends nothing once its skill updates. The per-profile allowlist and settings revision work is in this build but inert; alerts come back in a later release. A `/loop` with a count still runs on the box while the app is closed.
- Ships without the embedded baseline (P1b pending), like 0.6.0–0.6.5. Release text: [releases/v0.6.6.md](releases/v0.6.6.md).

## 0.6.5 (build 30)

- Dock icon: Light by default, independent of the theme; Settings → Appearance → App icon picks Dark.
- Webhooks out of the box: a supervised loopback receiver per box account, a Webhooks pane with delete; signed installs and upgrades set up or restart the receiver.
- Off-app alerts (swarmhub-messages 1.4.12): a per-server alerts pane; the box alerts on finished routines, code jobs, reports and webhook wakes (ntfy/email) while the app is closed. A `/loop` or `/goal` is handed to the box on quit and reclaimed when the app returns. See [off-app alerts](offapp-alerts.md).
- Routine suggestions: a bot offers a routine for a repeated ask, as a normal chat message with quick replies.
- Grok import: routines and connector requests imported staged and inert; one hardened single-pass secret filter.
- swarmhub-coding 1.3.15: after a deadline, code-job's kill_tree retries every tick until the job's whole tree is gone, signalling only pids it verifies as its own. The version bump makes existing 1.3.14 installs update.
- Ships without the embedded baseline (P1b pending), like 0.6.0–0.6.4. Release text: [releases/v0.6.5.md](releases/v0.6.5.md).

## 0.6.4 (build 29)

- New Hermes and OpenClaw bots receive only Swarm Hub's read-only default connectors (SB and the optional `default-connectors.json` policy). Creation uses a fresh stock backend profile/workspace instead of cloning a manager's config, `.env`, auth files or workspace. Non-default manager connectors and their credentials are never copied during creation. Hermes creation preserves the selected manager's model/provider login through a narrow credential transfer, without copying other provider or connector credentials. Existing bots are unchanged; missing or unsupported model auth fails before creation. Manager skill 1.5.1 updates older creation recipes.
- Other manager connectors are explicitly opt-in for one bot through the connector config helper. The selected connector and its credentials are copied only into that bot's private config; unrelated connectors and credentials remain on the manager. Default aliases retain their read-only policy.
- Migration: existing bots keep every connector they already have. Updating the app or manager skill does not remove, disable or narrow any existing bot's connectors. Retrying provisioning on a previously provisioned bot also preserves subsequent opt-ins. Review existing holdings with the read-only audit before deciding on any manual cleanup.
- Added an offline-capable connector audit. See [connector configuration](connectors.md). No Hermes code changes or release are required.
