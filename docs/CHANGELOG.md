# Changelog

## Unreleased

- Routine suggestions: the routine a yes asks for is converted to the box's time zone (read from its jobs' times, UTC when none say), at the offset of its next run, so DST and runs that cross midnight land on the time offered; the user still sees their own time. A routine the bot made on the converted schedule, or on the unconverted one a 0.6.5 lead asked for, counts as made, so the editor no longer invites a duplicate. The bot is asked for `deliver 'local'`.
- Off-app alerts (swarmhub-messages 1.4.13): the box alerts only for the profiles the app connected on that server (sent sealed with the settings) and skips script-only (`no_agent`) jobs. Box alerts stay off until set up in the app.
- Daylight saving time: Hermes runs cron in one zone per profile (UTC on our boxes) with no zone per job, so the app moves a routine its suggestion made when the clocks' difference changes (a Warsaw 09:00 routine is 07:00 UTC in summer, 08:00 in winter), once the next run is past the change; a routine changed since is left alone. The lead tells the bot, and the routine editor names the box's zone and says it does not change for daylight saving time. While the Mac is off across a change, runs until the app next reads the jobs can be an hour off.
- Off-app alerts: the allowlist is sent again whenever the connected agents on a server change (connect, archive, delete, the last one included) and to settings saved by 0.6.5; the box checks it again when an alert or a digest goes out, so a queued alert of a disconnected profile is dropped.

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
