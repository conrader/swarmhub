---
name: swarmhub-messages
description: "Use for any message to another bot on this box: asking it something, handing it work, answering it. Sends through SwarmHub's bot-msg (fast, shown in SwarmHub); supersedes `hermes -p … chat` and peer commands. Installed by SwarmHub, v1.4.0."
version: 1.4.0
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
   ~/.hermes/skills/swarmhub/swarmhub-messages/scripts/bot-msg --from default --to <bot> -- "<message>"
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

A held message holds at most 8,000 characters, and one turn receives at most 9,000 characters including policy
and held-message headers (below Hermes' default 10,000-character hook spill limit). Later messages stay queued
and are marked delivered only once their own turn answers. Previously queued messages that cannot fit remain
intact and unacknowledged, with a diagnostic in `~/.hermes/swarmhub/job-wake.error`; resend those using
`--priority` or `--durable`. An oversized legacy policy also remains unacknowledged until a shorter one is published.

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

Managed webhook routines: `scripts/swarmctl webhook register <profile> <routine>` creates a keyed URL that wakes the
profile; `webhook show <profile> <routine>` prints the URL and the key file path; `webhook rotate <profile> <routine>`
replaces the key (the old one is rejected at once); `webhook list` lists them. The key is generated into
`~/.hermes/swarmhub/webhooks/<unique-slug>.key` (0600, owner-only) and is **never printed**: hand the user the
file path, never its content, and never read it into a chat. A caller POSTs JSON `{"text": "..."}` to the URL with the
`X-SwarmHub-Key` header; `scripts/swarmctl webhook serve [port]` is the loopback receiver (127.0.0.1 only; policy
`webhook_base` sets the URL shown), and `webhook fire <profile> <routine> <slug>` with `{"key","text"}` on stdin is the
same check without HTTP. An accepted call journals one durable self-delivery for the profile (`[Webhook routine …]`).

Secure key intake: `scripts/swarmctl secret intake <name>` reads the value from **stdin** and writes
`~/.hermes/swarmhub/secrets/<name>` with mode 0600; it prints the path, never the value. Pass that path, not the key,
to provisioning. SwarmHub's secret-entry sheet writes the same kind of file on the user's Mac and hands the bot only
the path under `~/.hermes/swarmhub/secrets`, matching the runtime validator. A Mac-local path is not a remote intake path: when provisioning another host, request intake on that host;
do not claim the remote host can read the Mac's file. Never ask the user to paste a key into chat; ask for the sheet
or the intake command. Both writers replace files atomically with owner-only permissions.

Provisioning hook: the owner publishes `{"provisioner": ["/abs/path/to/provisioner", ...]}`; a `provision` action may
then omit `argv` and send a flat `request` object instead (`{"kind":"provision","request":{"name":"qa-hermes",
"model_key":"<intake path>"}}`). The record stores the composed argv (`<provisioner> --request <json>`) immutably;
secret-like request fields (`*key*`, `*secret*`, `*token*`, `*password*`) must name an existing owner-owned 0600 intake
file (not a symlink). Provisioning always
waits for the owner's decision.

The owner/coordinator can publish settings with JSON on stdin, for example:
```
printf '%s\n' '{"coordinator":"jarvis","owner":"konrad","route":"codex","allow_speculative":false,"timezone":"Europe/Warsaw","start":480,"end":1380}' | <skill-dir>/scripts/swarmctl policy set
```
Use actual local profile names. Settings persist independently of sessions. Subscribers receive each revision on
their next turn; managed admission and CLI dispatch read the current settings regardless of prompt text. `route`
controls coding CLI selection; it does not reconfigure the chat provider. `coding_gate` is `owner` by default:
every managed coding task waits for the owner's decision. The owner may publish `"coding_gate":"auto"` to let
Codex-only orders (workspace-write sandbox plus the verification sandbox) run without a card; an order that
includes claude waits for the owner regardless, because Claude Code runs on the host with the operator's shell. Set `codex_model` to an explicit supported
Codex model ID when rerouting jobs originally pinned to another provider's model. Never start speculative work while the
policy forbids it. `scripts/swarmctl report <sender-profile> "<result>"` journals delivery to the coordinator at all
hours and to the owner during the configured reporting window (08:00 inclusive to 23:00 exclusive by default).
This uses the IANA timezone with daylight saving changes. The owner is a configured receiving profile, not an OS
notification. Reports are routed when admitted and retain those recipients during retries.

Managed actions use `scripts/swarmctl submit` with JSON on stdin. Supported kinds: `coding`, `peer`, `read`, `outbound`,
`provision`, `money`, `prod`, `secrets`. Every action has `bot` and a stable `intent`. Peer actions include `to`, `text`
and optionally `parent`; external actions use an immutable `argv` array. Money/prod/secrets risks and provisioning
require the owner; real outbound text requires the coordinator. Outbound `argv` is composed from the owner's `outbound`
sender with the exact recipient and text; omit it, since a different caller-supplied `argv` is refused. Execution
rechecks the stored command against the current sender and exact draft, including records admitted before 1.3.8.
A mismatch or missing sender fails the action; resubmit for approval after reviewing the current configuration.
The runtime never silently changes an approved command. Only absolute system `pwd`, `ls`, `stat` commands
are automatically allowed reads; other commands ask the owner. Any action with `fake: true` is a dry run: it keeps
its gate, then records `FAKE: no <kind> operation executed` and never executes its argv, launches a coding CLI or
admits a delivery. A FAKE task ID cannot authorize direct execution or peer sends, even after completion.
Stop/replace act on IDs; do not resubmit denied work with another ID or label.

`scripts/swarmctl decide <task-id> <deciding-profile> approve|deny` is the local administrative decision interface.
Only the configured role is accepted, and only from its own gateway: `swarmctl` reads the deciding profile from
`HERMES_HOME` and refuses a decision when it is unset or names another profile; actor, pid and time are recorded on
the action. The stored action is immutable and denial is final by intent and operation. Bots must present awaiting
approvals to that role, never impersonate it to decide. Present one by ending the reply with a `swarmhub` fence that
SwarmHub treats as a notification. For a local runtime, the app fetches `swarmctl control get <task-id>` directly
and renders only its authoritative spec; the fence fields never authorize an operation. The app submits JSON
`{"fingerprint":"<record fingerprint>","gate":"<current gate>","approved":true|false}` to
`swarmctl control decide <task-id> <deciding-profile>` with that profile's HERMES_HOME. The transaction checks both
bindings and role, and the card stays pending until its runtime receipt confirms the decision. Remote runtimes use the authenticated SwarmHub transport described below; unavailable or unverified transport
fails closed, and the app never asks a model to decide instead. The opening line must be exactly three backticks followed by `swarmhub`,
then JSON on the next line, then three backticks alone on the closing line. Bare JSON, a `json` fence, or saying
"swarmhub fence" in prose does not follow this output contract. Example (replace these example values with the
actual awaiting record; never invent a task):
```swarmhub
{"op":"approval","task":"task.0123456789abcdef0123456789abcdef","kind":"outbound","gate":"coordinator","decider":"jarvis","bot":"infra","intent":"release-note","summary":"Email Ada the release note","risks":[],"draft":"Hello Ada"}
```
Only present a card for an actually awaiting record. App Draft Send always submits `fake: true`, with the exact text,
recipient and stable card intent. It reports the returned task's actual status; an automatic FAKE record needs no
approval. Never turn that record into a real send. A card click sends a decision request to the configured profile
through the local or authenticated remote control interface; only its matching authoritative receipt proves acceptance.
To obtain a user secret, end the reply with this exact fence format, replacing the name and reason as needed.
Never put the secret value in JSON or chat:
```swarmhub
{"op":"secret_request","name":"openai-key","reason":"To provision QA Hermes"}
```
SwarmHub opens its secret-entry sheet and replies with the 0600 file path only. All these scripts run under the
owner's Unix account: this interface is a trusted local control plane, not identity isolation against a malicious
bot with unrestricted shell/file access. Gates cover managed entrypoints; unrelated tools and external connectors
still require their own permission boundaries. Use `--task-id <id>` on associated messages so Stop propagates to
held messages and running streams. Gateways must cancel model runs when their client stream disconnects, as Hermes
does; remote tool side effects already accepted cannot be undone by Stop.


## Remote managed approvals (operator setup)

Install/update this skill on the remote box. Run its app-owned service under the same Unix account as the managed
runtime, with HOME pointing to that account. This does not change Hermes code or its plugin/API routes:

```sh
python3 /absolute/path/to/swarmhub-messages/scripts/swarmctl control serve https://hermes.example.com 8653
```

Use the exact existing Hermes HTTPS origin (lowercase host, explicit port if configured in the app, no `/v1`).
The service binds **127.0.0.1 only**; keep port 8653 private. Supervise this command with the box's process manager.
On the existing TLS reverse proxy, route only `/swarmhub/control/v1/` to `http://127.0.0.1:8653`, preserving the
path and `Authorization` / `X-SwarmHub-Signature` headers. For nginx inside the existing HTTPS server block:

```nginx
location ^~ /swarmhub/control/v1/ {
    client_max_body_size 1m;
    proxy_pass http://127.0.0.1:8653;
    proxy_set_header Authorization $http_authorization;
    proxy_set_header X-SwarmHub-Signature $http_x_swarmhub_signature;
    proxy_read_timeout 20s;
    add_header Cache-Control "no-store" always;
}
```

The app uses its existing Hermes connection and `hermes` / `hermes.<profile>` Keychain account. The server reads
the existing profile's `API_SERVER_KEY` from `.env` on every request, just as bot-msg does; never paste keys into
this command, proxy configuration, new files or chat. The submitting profile may read its own operation; only
the configured deciding profile may decide. Keep the deciding profile's key private.

Requests and responses have domain-separated HMAC-SHA256 authentication in addition to HTTPS and Bearer auth.
Each request binds the origin, profile, operation ID, nonce and a maximum 60-second validity window. Decisions
also bind the persisted runtime UUID, fixes5 fingerprint, gate and exact boolean choice. Responses bind to the
hash of the complete request. Runtime identity, nonce use and atomic decision receipts live in the existing
private control SQLite database. Do not clone that database to another independently writable runtime at the
same origin; a restored/replaced runtime needs fresh cards. Clock skew, changed scope, expiry, redirects, missing
service/key and ambiguous receipts fail closed. Keep clocks synchronized.

Cards retain the reviewed binding and original decision across uncertain responses/restarts. Retries query first;
only a matching authenticated receipt confirms the decision. Never turn a failed transport into a model turn or CLI
impersonation. The existing peer worker executes committed approved operations; service startup is separate from
Hermes, and setup requires no Hermes source modifications. No independent secret is generated or stored.

Remote approval recovery: a choice is locked only once its decision request may have been dispatched; an offline
status lookup or a provably unsent request allows another choice. Authenticated gone/superseded responses retire
stale cards with an audit note. Saved receipts retain their original deciding profile after policy changes; new
decisions require the current profile. Denial cancellation markers are emitted from a durable outbox after commit.

`scripts/swarmctl update-status` prints the box updater's status file (read-only: applied bundle, pending code
confirm, reload_pending); it never runs or changes the updater.
