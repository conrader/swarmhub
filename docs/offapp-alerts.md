# Off-app alerts, and loops and goals while Swarm Hub is closed

**Switched off in 0.6.6** (swarmhub-messages 1.4.14), until concurrent saves from two Macs can no longer defeat the
box's revision check. One switch per side: `AppStore.boxAlertsShipped` (no section, no box call, no presence lease) and
`swarm_alerts_service.ON` (no install or resume, saved settings turn alerts off, a running service sends nothing). To
bring them back: both to true, bump the skill, drop `sim/test_alerts_off.py` and `BoxAlertsOffTests.swift`. Loops still
go to the box at quit (below); `--until` loops and goals stay in the app either way.

Swarm Hub step 2. A box tells you what happened while the Mac app is not there to show it. A `/loop` or `/goal` in a
bot's main chat keeps running on the box while the app is closed.

## What gets an alert

One service per box account, `swarmctl alerts run` (skill `swarmhub-messages` 1.4.12+, profile scope 1.4.13+, `scripts/swarm_alerts*.py`).
It checks every 30 seconds:

| Source | How it is seen | Alert id (sent at most once) |
|---|---|---|
| Finished routine runs | `GET /api/jobs` on loopback of each profile the app connected (the `profiles` list it seals with the settings on every save, and sends again whenever the agents it connected on that server change, a deletion included; none from an app older than 0.6.6, and no other profile on the box), with the profile's own `API_SERVER_KEY`; agent jobs only (a `no_agent` script has no reply); output from the run's cron session, like the app's `runResult` | `routine:<profile>:<job>:<last_run_at>` |
| Code jobs | managed coding actions that reach `done`/`failed` in Swarm Hub's own database | `codejob:<action id>` |
| Bot reports | `swarmctl report` spools one event | `report:<delivery id>` |
| Webhook wakes | an accepted webhook call spools one event | `webhook:<delivery id>` |
| Loops and goals handed to the box | the bot's reply to the job's own delivery row in its Bot Chat | `loop|goal:<profile>/<job>:<delivery time>` |

A job's first sighting, and every code job that existed when alerts were turned on, is only recorded. Nothing from
before is sent.

Before anything is sent:
- The scope is checked again: an alert, or a digest line, of a profile no longer in `profiles` (or of a script-only job) is
  dropped, however long it waited for a retry or a digest.
- `[SILENT]` and `NO_REPLY` replies are dropped.
- While the app's presence lease is fresh, nothing is sent (see below).
- Outside the box policy's reporting window (`timezone`, `start`, `end`; 08:00 to 23:00 by default, the window
  `swarmctl report` already uses), alerts wait. They go out as one digest when the window opens. You can switch this
  off per server.
- At most 6 alerts in 10 minutes. Further alerts are held and sent later as one "N more alerts were held back" digest.
- A failed send is retried with backoff (2, 4, 8, 16 minutes) up to 5 times. The error is shown in the app with any
  token or password removed.

## Sinks

- **ntfy** (default): a topic URL such as `https://ntfy.sh/<topic>`, with an optional access token (sent as
  `Authorization: Bearer`). Plain `http` is allowed only to 127.0.0.1.
- **Email**: SMTP with STARTTLS (587), SSL (465), or no encryption to a relay on the box itself.

Each sink is one function in `swarm_alerts_sinks.py`. To add one, add a function and register it in `SINKS`.

## Where the settings and secrets live

- **Mac:** the ntfy token and the SMTP password are Keychain items (`swarmhub.alerts.ntfy|smtp.<server>`). The other
  settings are in UserDefaults. No secret is in either.
- **Over the wire:** the box has its own X25519 key (`~/.hermes/swarmhub/alerts/box.key`, 0600). Its public half comes
  back with every panel answer. The app seals the settings JSON to it: an ephemeral X25519 key, HKDF-SHA256, an
  HMAC-SHA256 key stream and a 16-byte HMAC tag (`swarm_alerts_seal.py`, `AlertSeal` in `BoxAlerts.swift`; both test
  the same vector). The one terminal call that reaches a remote box goes through a model turn, so the model, the
  session transcript and Hermes' logs see only ciphertext. A changed or wrong blob is refused.
- **Box:** `~/.hermes/swarmhub/alerts/config.json`, 0600, in a 0700 folder. The service and the panel never print it.
  Errors are redacted before they are stored.

## The app's pane

Settings → Advanced → Appearance and alerts → **When SwarmHub is closed** has one row per server. The row has:
- ntfy and email settings;
- **Save and start**, which seals the settings, saves them on the box and installs the service;
- **Send test alert**;
- **Turn off**, which saves `enabled: false` and removes the service;
- the service state: running or not running (from the service's heartbeat, younger than 90 s), when the last alert was
  sent, the last error, and whether the presence lease is holding alerts back.

On a box, each click is one paired terminal call in a deleted throwaway session. This is the Webhooks section's
transport, now shared as `swarmctlBoxTurn`. A box therefore loads only on click. With Hermes on this Mac, the call is a
subprocess and loads by itself.

## No double alerts: the presence lease

The Mac app shows routine cards and local notifications itself. A phone alert at the same time would be a duplicate.

- While Swarm Hub runs and you have used the Mac in the last 10 minutes (keyboard, mouse or trackpad), the app keeps a **presence lease** on every server with alerts on. The lease is a paused Hermes routine named
  `swarmhub-presence` whose prompt ends in `until=<unix seconds>`. Every 2 minutes the app sets it to now + 5 minutes
  through the jobs API it already uses. This costs one PATCH, with no model turn.
- The box reads the lease with the same `/api/jobs` call it makes for routines. While `until` is in the future, every
  alert is marked "app" and dropped. It is an acknowledgement for everything at once: the app is there and shows it.
- Quitting the app sets `until=0`, so alerts start at once. After a crash or when you walk away, the lease lapses within
  5 minutes.
- The routine never runs (paused, scheduled once a year). If someone resumes it, it answers `[SILENT]`. The Routines
  tab hides it, along with the handed-off loop and goal routines.
- When in doubt the box sends: if the lease cannot be read, it alerts. A duplicate is better than a missed alert.

Known edge: an event in the last minutes before you walk away, which the app had not shown yet, is not sent once the
lease lapses. The app shows it when you come back.

## Loops and goals while the app is closed

Today's in-app timer is unchanged and stays the fallback. At quit (`applicationWillTerminate`, at most 4 seconds,
requests on a detached task):

- Every active `/loop`, and every running `/goal`, in a bot's **Bot Chat** becomes one Hermes routine. This needs a
  jobs API and the chat titled "Bot Chat".
  - The routine is named `swarmhub-loop-<chat id>` or `swarmhub-goal-<chat id>`, with `deliver: bot-chat:<profile>`.
  - Like a heartbeat, the routine's own run only repeats the prompt. Hermes hands that text to the Bot Chat for a full
    turn, so the bot works with the chat's context.
  - A loop keeps its interval, with `repeat` set to the remaining `--times`.
  - A goal gets a round every 15 minutes, with `repeat` set to the remaining rounds within its time budget.
- The handoff is saved before the request. A routine the box created after the app gave up waiting is found by name.
- The alert service, when it runs, alerts with each reply to the routine's own Bot Chat turns. A turn is matched by
  the delivery row Hermes writes (`[Cronjob "<name>" output — …]`, the name holds the chat id) and by time: after this
  job was made and after its previous run. Any other reply in the chat, however new, is not this routine's: it never
  ends the wait, sends an alert or pauses the routine. The service pauses the routine when a matched reply carries the
  loop's done block or the goal's done or blocked block. That end is alerted only once the pause is confirmed (it went
  through, or the box lists the routine disabled or gone). Until then the service keeps the handoff, past its 30-minute
  wait, and tries the pause again on every tick.

At launch, on every routine poll tick until none is left:
1. **Pause first.** No run starts after this point. A box that cannot be reached keeps the routine. Nothing runs in the
   app meanwhile, so nothing runs twice. The next tick tries again.
2. The Bot Chat is read from the box, the whole session (this chat only, not its threads). The app goes on only when
   that read happened and every delivery turn of this routine is in the chat (a round paired with a reply here that
   conflicts with the box's, or is shorter and finished, is not), or when the box says it has no session
   for the chat and the routine is there and never ran (no `repeat.completed`, no `last_run_at`, nothing in flight).
   Every round of a routine has the same text, so a turn read from the box earlier keeps its own box turn (by id), and a
   delivery is taken for a copy only of an unpaired, id-less row with its own text (never of a reply alone). A delivery
   turn left out from before this handoff (e.g. an earlier quit's) does not hold it back. Each wait (a busy chat, a run in
   flight, replies not in the chat yet) has its own clock. Otherwise (the read fails, the box has no session reads,
   the box's turns cannot be merged, or the session is missing although the routine ran) the routine stays on the box,
   paused, and the handoff stays. The chat says why, once. The next tick tries again. A chat that is busy is read on
   the next tick; one still busy after 20 minutes says so once.
3. The box's rounds are counted: each delivery row since the handoff that has a reply. If Hermes counted more runs
   (`repeat.completed`) than the chat has replies, the app waits up to 20 minutes for them. After that the routine
   stays paused on the box: a missing reply may hold an `--until` met or a goal's done block. The chat says so once and
   offers `/loop takeover` (or `/goal takeover`), which continues here with the box's count, or a stop, which deletes
   the routine. A run still in flight is never taken over, however long it runs: Hermes counts a run only after its
   delivery, so taking it back then could run that round twice. After an hour the chat says it is still waiting and
   that stopping the loop or goal ends it. A read that cannot merge keeps failing until the user stops the loop or
   goal; the chat line says so.
4. The routine is deleted. Only then is the handoff cleared. A delete that fails keeps everything for the next tick.
5. The loop's run count and `--times` are updated, and its next run is one interval after the box's last run. An
   `--until` met on the box ends the loop.
   - The goal's round count is updated. The last box reply is judged like any reply: done, blocked, or the next round.
6. The chat gets one line: "While SwarmHub was closed, the box ran this loop N times."

**Not handed off:** loops and goals in threads and groups (a routine has no access to their context); paused loops; and
boxes with no jobs API or no Bot Chat. These wait in the app, as before. A stop while a handoff is still pending keeps
the record until the routine is deleted. Nothing is resumed then, so the routine is deleted without waiting for a read.

**Ending needs the alert service.** A `--until` loop and a goal end by a reply, and only the alert service reads that
reply and pauses the routine. The app can't confirm at quit that the service is on and running now: that takes a box
turn, which the 4-second quit budget doesn't allow, and its own record (`alerts.on.<server>`) may be stale, for example
when another Mac turned alerts off since. So these always stay in the app at quit, and the chat says so once (a known
limitation: they don't run while SwarmHub is closed). A loop that only ends by its `--times` or a stop still goes.
Every answer from the alerts panel, a refresh included, updates `alerts.on.<server>`.
Turning alerts off on the box, or removing its service, first pauses every handed-off routine there (`pause_handoffs`;
routines handed off earlier or by an older app); the app takes it back paused at its next launch, as above. This fails
closed: if a profile's routine list can't be read or a pause fails, nothing is saved or removed, the alerts stay on and
the panel shows the error; the next try pauses them again.

## Supervision

The service is supervised like the webhook receiver:
- **Linux:** the systemd user unit `swarmhub-alerts.service` (Restart=on-failure, journald).
- **macOS:** the LaunchAgent `com.swarmhub.alerts`.
- **No user manager** (Hermes as a system service, no lingering): the service holds the account's lock file itself. A
  marker records the fallback, and the peer plugin starts the service again at each gateway start. Removing the marker
  (Turn off) stops it within a second.
- When its code changes on disk, the service re-executes itself, so a skill update needs no reinstall.

## Testing

- **Python** (run in the sandbox): `sim/test_alerts.py` and `sim/test_alerts_service.py`. They use loopback fakes for
  Hermes, ntfy and SMTP (`sim/alerts_fixtures.py`).
- **Swift:** `BoxAlertsTests.swift`, `AutomationHandoffTests.swift` and `AutomationHandoffAlertsTests.swift`.
- **Screenshots:** `AgentApp --render-setup <dir> --only alerts`.
