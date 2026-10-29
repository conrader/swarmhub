# Changelog

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
