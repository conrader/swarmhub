---
name: swarmhub-messages
description: "Use for any message to another bot on this box: asking it something, handing it work, answering it. Sends through SwarmHub's bot-msg (fast, shown in SwarmHub); supersedes `hermes -p … chat` and peer commands. Installed by SwarmHub, v{{VERSION}}."
version: 1.3.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub messages

Use this for every message to another bot on this box. Do not run `hermes -p <bot> chat`, `hermes chat`, `hermes peer`
or `send_message` to reach a bot; this replaces them and is much faster. The bot names are the profile names
(`ls ~/.hermes/profiles`; `default` is the main profile).

How to send:
1. Write one short, self-contained message: what you need, by when, and what to send back.
2. Run it with your terminal tool:
   ```
   {{SKILL_DIR}}/scripts/bot-msg --from {{BOT}} --to <bot> -- "<message>"
   ```
   This is held delivery: it returns a `held:<id>` receipt without contacting the gateway or starting a model turn.
   The message joins the recipient's next turn through the SwarmHub peer plugin. `--held` makes this explicit.
   For an action or an answer needed now, add `--priority`. Priority starts the recipient immediately and waits for
   its reply (up to 5 minutes; `--wait <seconds>` changes that). `--priority --no-wait` starts it and returns at once.
3. Report what the other bot said, in a line or two, in your own reply.

Late replies: with `--priority --no-wait`, or when no reply came in time (exit 124), the other bot's reply still reaches you (up to
30 minutes later) as a new message starting with `[Reply from <bot> via SwarmHub]`, in your thread titled `From <bot>`.
That message is the answer you asked for: finish the task it belongs to and tell Konrad what came of it. Do not answer
it back to that bot and do not send it on with bot-msg; it is not a new request.

Every message arrives starting with `[Message from <bot> via SwarmHub]`, in a thread titled `From <bot>`. When a
message you receive starts like that, it is from that bot: answer it right there in the same thread, short and to the
point; your answer is what the sender gets back. Do not message that bot back separately about the same thing.

Exit codes: 0 sent (the reply is on stdout; with `--no-wait`, the thread id); 2 no such bot or it has no key; 3 the
other bot's gateway failed; 124 no reply in time (its reply will reach you later as a new message). Say which, if it is
not 0.

Never print, read or copy another bot's `.env` or API key; bot-msg reads what it needs itself.

Acknowledgements: answer exactly `NO_REPLY` when no action or useful answer remains. `NO_REPLY` and `[SILENT]`
(trimmed, case insensitive) never cause a reverse reply wake. A substantive reply mentioning either marker is kept.

Runtime: Python 3 with SQLite is required for held messages and coding completion recovery. SwarmHub's Install writes
and enables the `swarmhub-peer` Hermes plugin in this profile. Reload the Hermes gateway's plugins (or restart the
gateway when idle) after installation; it supplies held messages to any next turn, including app and routine turns.
The inbox is private SQLite state under `~/.hermes/swarmhub/`. Successful turns acknowledge their held batch;
an unanswered or interrupted turn leaves it pending (same-session next turn, otherwise after a one-hour claim lease).
Neither held messages nor acknowledgements start an extra model turn.

Coding completion wakes use `bot-msg --priority --no-reply` internally. `bot-msg --retry` restarts the durable outbox
worker without a model call; plugin startup and code-job exit also start it. Configure unknown-origin fallback with
`COORDINATOR=<profile>` in `~/.hermes/swarmhub/coding.conf` (preserve `SLOTS`), or `SWARMHUB_COORDINATOR` in the worker's
environment. Credentials are resolved from the target profile at delivery time. Never copy keys into these settings.

Durable priority delivery: add `--durable` for a journalled action message. It returns `pending:delivery.<id>`, meaning
admitted, not delivered. The persistent worker retries until a terminal acknowledgement, including after restart.
`scripts/swarmctl status` shows pending/delivered/cancelled, attempt count and the last error. Ordinary priority sends
that cannot reach the gateway before submitting a chat also queue a retry, retain exit 3 and print a pending receipt
on stderr. Use `--durable` when delivery must survive a crash at any point. A completed receiver turn acknowledges
its stable delivery ID in the receiver journal; a lost sender ACK does not repeat acknowledged work.

Register for wakes and global policy with `scripts/swarmctl register <profile>`. Add `--coordinator` to register the
fallback coordinator. Installation registers the receiving profile automatically. Registration uses the existing
profile gateway and its current `.env` reference; it creates no new public endpoint or webhook key and never prints
or copies a credential. This provides the requested wake subscription through the existing authenticated gateway.

The owner/coordinator can publish settings with JSON on stdin, for example:
```
printf '%s\n' '{"coordinator":"jarvis","owner":"konrad","route":"codex","allow_speculative":false,"timezone":"Europe/Warsaw","start":480,"end":1380}' | <skill-dir>/scripts/swarmctl policy set
```
Use actual local profile names. Settings persist independently of sessions. Subscribers receive each revision on
their next turn; managed admission and CLI dispatch read the current settings regardless of prompt text. `route`
controls coding CLI selection; it does not reconfigure the chat provider. Set `codex_model` to an explicit supported
Codex model ID when rerouting jobs originally pinned to another provider's model. Never start speculative work while the
policy forbids it. `scripts/swarmctl report <sender-profile> "<result>"` journals delivery to the coordinator at all
hours and to the owner during the configured reporting window (08:00 inclusive to 23:00 exclusive by default).
This uses the IANA timezone with daylight saving changes. The owner is a configured receiving profile, not an OS
notification. Reports are routed when admitted and retain those recipients during retries.

Managed actions use `scripts/swarmctl submit` with JSON on stdin. Supported kinds: `coding`, `peer`, `read`, `outbound`,
`provision`, `money`, `prod`, `secrets`. Every action has `bot` and a stable `intent`. Peer actions include `to`, `text`
and optionally `parent`; external actions use an immutable `argv` array. Money/prod/secrets risks and provisioning
require the owner; real outbound text requires the coordinator. Only absolute system `pwd`, `ls`, `stat` commands
are automatically allowed reads; other commands ask the owner. An outbound action with `fake: true` records FAKE
without executing its argv. Stop/replace act on IDs; do not resubmit denied work with another ID or label.

`scripts/swarmctl decide <task-id> <deciding-profile> approve|deny` is the local administrative decision interface.
Only the configured role is accepted; the stored action is immutable and denial is final by intent and operation.
Bots must present awaiting approvals to that role, never impersonate it to decide. All these scripts run under the
owner's Unix account: this interface is a trusted local control plane, not identity isolation against a malicious
bot with unrestricted shell/file access. Gates cover managed entrypoints; unrelated tools and external connectors
still require their own permission boundaries. Use `--task-id <id>` on associated messages so Stop propagates to
held messages and running streams. Gateways must cancel model runs when their client stream disconnects, as Hermes
does; remote tool side effects already accepted cannot be undone by Stop.
