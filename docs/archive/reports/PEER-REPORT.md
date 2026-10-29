# Peer delivery and coding completion wakes

Implemented the P03 and P01/P02 gaps from `LIVE-REPORT-3.md` in this worktree.
No commit, live gateway deployment, provider call or credential change was made.

## Behavior

- `bot-msg` now defaults to held delivery (`--held` is explicit). It persists the
  message in a private SQLite inbox and returns `held:<id>` without an HTTP
  request, session creation or model turn. `--no-wait` alone remains held.
- `--priority` uses the existing immediate gateway/stream path. Add `--no-wait`
  for an asynchronous priority request; timed-out priority requests retain late
  reply handling. Existing callers that need an immediate answer must add
  `--priority`; the shell regressions, app snapshot fixtures and LIVE3 runner
  have been adjusted accordingly.
- The bundled `peer-runtime.py` supplies Hermes `pre_llm_call` / `post_llm_call`
  callbacks. The recipient's next turn claims held messages in creation order,
  scoped to that profile, and receives them as attributed user context. It works
  for app, peer and routine turns without an additional model turn. Batches are
  bounded to 50 messages / 32,000 text characters; excess remains queued.
- A whole trimmed `NO_REPLY` or `[SILENT]`, case insensitive, never triggers a
  reverse late-reply wake. A substantive answer containing either marker remains
  deliverable. Failed and truncated streams are not successful deliveries.
- The app parses/persists delivery priority, displays “Held for …’s next turn”,
  keeps held recipients out of the active-request indicator, and hides quiet
  acknowledgements in replies and thread previews. Older saved calls without
  priority keep their previous immediate-delivery interpretation. The held chip
  describes the send mode; it is not a live acknowledgement of inbox consumption.
- Every normal `code-job` finish, including failure, timeout, interruption and
  delegate handoff, publishes `~/.hermes/swarmhub/job-completions/job.*` before
  removing temporary output. Records contain worker/origin, directory, agent,
  status, exit code and timings. Task text, CLI output and credentials are absent.
  A `ready` marker publishes the completed record; `delivered`, attempt count,
  retry deadline and a generic last error preserve delivery state.
- Origin precedence is `--origin`, `SWARMHUB_ORDERING_BOT`, then the sender in a
  Hermes terminal's `HERMES_SESSION_ID=swarmhub-from-<sender>`. An absent or unknown
  profile falls back to `SWARMHUB_COORDINATOR`, then `COORDINATOR=<profile>` in
  `~/.hermes/swarmhub/coding.conf`. Missing configuration leaves the job pending.
- A detached worker scans the outbox under an OS process lock and retries with
  increasing delay (capped at 256 seconds), without a retry ceiling. It uses
  `bot-msg --priority --no-reply` and reads the target's current profile `.env`
  through bot-msg each attempt. Key rotation needs no copied key. A terminal,
  nonfailed reply, including `NO_REPLY`, marks the job delivered. Coding slots
  are released before wake delivery; a wake failure preserves the CLI exit code.

## Installation and recovery

Both affected bundled skills are version `1.2.0`. Install/update SwarmHub skills
on the bots. The app's single-bot and all-bots install paths write a profile-local
`swarmhub-peer` plugin, enable it with `hermes -p <profile> plugins enable
swarmhub-peer`, and start completion recovery. Python 3 with SQLite and Hermes
support for these plugin hooks are required. Enabling can activate hooks on a
running gateway; if activation/reload is unavailable, reload plugins or restart
the gateway when idle. No Hermes source patch or extra HTTP endpoint is needed.
Install messaging on each recipient to enable held delivery, and alongside coding
to launch completion wakes. The app does not install anything on a box until its
normal Install flow is used.

Configure the fallback bot name in `coding.conf`, preserving any `SLOTS` line.
The fallback does not infer or hardcode Jarvis. A surviving worker retries while
the gateway is offline; plugin startup recovers records after a gateway/box
restart. `bot-msg --retry` or a subsequent code-job also starts recovery. Killing
the worker alone requires one of those startup paths to run again.

Held claims with no final answer remain pending: the same session's next turn
can reclaim immediately; a different session waits for the one-hour lease to
expire. Completed records and consumed inbox rows are retained. Completion wakes
are **at least once**: an uncertain disconnect or a crash before recording the
acknowledgement can repeat a wake with the same job ID. The wake explicitly asks
the ordering bot to avoid repeating follow-up work for that ID; this is not an
exactly-once action guarantee. SIGKILL/power loss before code-job publishes
`ready` does not synthesize a completion. Exit 75 reports a delegate handoff,
not completion of the delegated coding work. CLI exit zero does not verify an
artifact, report or commit (P04 is outside this change).

## Validation

- `python3 -B -m unittest discover -s sim -p 'test_*.py'`: **69 passed**, including
  13 new peer regressions. They execute the shipped scripts with a file-based
  synthetic curl boundary and exercise inbox isolation/concurrent claims, hook
  registration, next-turn consumption/recovery, priority and late `NO_REPLY`,
  real code-job record production with a stub CLI, origin/coordinator routing,
  missing configuration, retries from a fresh process, rotated credentials,
  failed/truncated streams and concurrent outbox workers.
- `Tests/Scripts/code-job-test.sh` under `/bin/sh` and `/bin/dash`: **15 passed
  per shell**. Shell syntax checks for both modified scripts passed under both
  shells. `git diff --check` passed.
- Added five Swift tests in `PeerDeliveryTests.swift` for delivery parsing and
  persistence/backward compatibility, quiet replies/history, held app state and
  plugin installation commands; updated existing immediate-delivery fixtures
  and skill-version assertions. **Not compiled or run: no Swift on this box.**
- The existing socket-based `bot-msg-test.sh` was attempted but cannot start its
  loopback gateway: this sandbox refuses socket creation with `EPERM`. The new
  Python tests use no sockets. No live Hermes or native macOS behavior is certified.
  The LIVE3 runner now checks held admission and explicitly marks actual held
  next-turn delivery blocked because its temporary HOME/bridge does not install
  the plugin on the remote gateway. Historical LIVE reports/results are unchanged.
