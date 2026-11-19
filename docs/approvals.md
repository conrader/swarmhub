# Approvals

How much a bot may do without asking, who it asks, and how that is adjusted. This is the behaviour SwarmHub promises and the plan it is tested against. What exists today is at the end.

## The idea

An approval is a question about one action a bot is about to take: run this command, change this file, send this message. Three things are adjustable, separately for every bot and with a default for the server:

1. **How much is asked** (the level of control).
2. **Who answers** (you, a reviewer bot, or a rule).
3. **What happens when nobody answers.**

## Levels of control

| Level | What the bot may do without asking |
|---|---|
| Ask about everything | Nothing that changes anything; reading only |
| Ask about risky actions (default) | Ordinary work in its own folder and projects; it asks before deleting, sending, spending, deploying, or touching anything outside them |
| Ask a reviewer | The same questions, answered by a reviewer bot instead of you |
| Trusted | Everything; nothing is asked, everything is logged |

A level is a preset of rules, not a separate mechanism, so it can be adjusted rule by rule.

## Rules

A rule says: for this kind of action (a tool, a command pattern, a file pattern, a project, a server), do one of: allow, ask me, ask a reviewer bot, refuse. Rules are read top to bottom; the first match wins: the bot's own rules, then the server's, then the level's preset. A rule can be permanent or last for a time ("allow deploys to staging for the next hour"). Answering a request offers "always allow this here" as a new rule, so control loosens from use rather than from configuration.

## Reviewers

Any bot can be a reviewer, including the main bot. A reviewer receives the request with what the asking bot is trying to do and why, and answers approve, refuse (with a reason), or "ask the person". Rules for reviewers:

- A bot never reviews its own request, and a reviewer cannot approve what its own level would not allow it to do.
- A reviewer that is unsure, or that does not answer in time (default 2 minutes), passes the request to you. It is never approved by silence.
- Every request, who answered and why is shown in both chats and kept in a log you can read per bot.
- You can answer any pending request yourself at any time; your answer wins.

## When nobody answers

A request that reaches you waits. The bot is told it is waiting and may continue with other work that needs no approval. You can set a per-bot rule for unanswered requests: keep waiting (default), refuse after a time, or fall back to the agent program's own prompt in its terminal.

## How this is made to hold

- **Enforced by the workspace, not by the bot's goodwill:** the agent programs call the workspace before an action that needs permission; the workspace applies the rules and the answer. A bot cannot approve itself by saying so. This is unit-tested: rule order, expiry, reviewer eligibility, time limits, the log.
- **Limits stated honestly:** the workspace sees the actions the agent program reports as needing permission. An agent program run in a mode that asks about nothing gives the workspace nothing to decide, so "Trusted" and the agent program's own settings must agree; the app shows when they do not. All bots on a server run under one account, so approvals are a control on what bots do, not a wall between them.
- **Measured with real agents** (ten runs each with Claude Code and Codex, bar 9 of 10): a risky action is asked about and waits; an allowed action is not asked about; a refused action is not done and the bot says so; a reviewer approves a safe request and refuses an unsafe one for the stated reason; an unsure reviewer passes it on; a silent reviewer leads to you, not to approval; "always allow this here" stops the next identical request; a timed rule stops applying when it ends.

## What exists today

The workspace can already receive permission requests from Claude Code and Codex when a template opts in, show the exact action, and take allow once, deny, or "use the terminal" from its browser page, with a decision record. The Mac chat also offers **Allow once** and **Deny** for its current session. Configurable levels and reviewer bots remain on the roadmap.

## Fleet policy and signed park decisions

Fleet policy governs durable decisions about immutable parks. The staging-ref adapter advances one configured ref between reviewed commits in a disposable Git repository. Only the Rust test harness can enroll that project and run the adapter. The provider permission prompt still uses the interactive approval flow above. The fleet authority check accepts an operator decision or a registered bot's signed request. Browser access, bot display names, the main-bot flag, group form answers and chat quotes supply no fleet decision evidence.

The bridge and operator commands use the deployment's `SWARMHUB_FLEET_POLICY_DIR`, `SWARMHUB_FLEET_OPERATOR_UID` and `SWARMHUB_FLEET_WORKSPACE`. Provision the directory under a distinct, non-root operator account and give the bridge read access. Use a stable absolute path without symlinks or writable parents controlled by the bridge, and on macOS use an ACL-free directory and ancestry. Provision an operator-owned, empty `policy.lock` and an operator-owned `trust.json` with `workspace`, `operator_key` and optional `delegate` containing `bot_id` and `key`. The bridge expects the configured workspace ID and operator ownership. Public keys are standard padded Base64 of 32 raw Ed25519 bytes. Keep the operator signing key under the operator identity. Delegated execution requires a separately protected Jarvis signer with its own key because agent terminals share an OS account. Trust enrollment supports one delegate signer and one stable bot ID per workspace. Both the judge and the backstop use that delegated identity. An unavailable trust boundary or signer holds the request.

All input to the following commands is JSON on standard input.

- `swarmhub-herdr fleet-policy digest` reads a policy containing `generation`, `rules` and `revoked` and prints its generation and SHA-256 digest. Generations start at 1. Each publication advances by one, and revoked rule IDs carry forward.
- `swarmhub-herdr fleet-policy payload` reads an envelope and emits the exact UTF-8 bytes for signing. The first line is `swarmhub-fleet-decision-v1`. The JSON on the next line is compact and has no trailing newline. Fields are `workspace`, `principal`, `purpose`, `target`, `nonce`, `issued_ms`, and `expires_ms`. An operator principal is `{"kind":"operator"}`. A bot principal has `kind:"bot"`, stable `id` and current `launch`.
- For `publish_policy`, use a target with `kind:"policy"` and `policy` set to the generation and digest. For a park decision use `kind:"park"`, the same `policy` reference and a `park` with `id`, `revision` and `manifest_digest`. The operator can sign `execute`, `release`, `hold` and `deny`. The delegate signs `execute` for a judge decision or `auto_execute` for the backstop. Times are Unix milliseconds, and the end of an interval is exclusive.
- For `supersede`, use `kind:"supersession"` and include a `replacement` pin alongside the original `park` and current `policy`. Generate a replacement pin offline with `swarmhub-herdr fleet-policy park-pin` using `{"id": …, "manifest": …}` on standard input. The replacement keeps the owner, project and host and gets its own revision and decision.
- Sign offline. On the operator account, `swarmhub-herdr fleet-policy import-policy` reads `{"policy": …, "signed": {"envelope": …, "signature": …}}`. `swarmhub-herdr fleet-policy import-decision` reads the signed object and returns its nonce. Encode the raw Ed25519 signature with standard padded Base64. Exact retries are safe. Key enrollment and signing take place outside the bridge.
- `swarmhub-herdr fleet-policy inspect` and the authenticated `GET /api/bots/fleet-policy` show the trusted current policy. The bridge copies published generations to schema v55 on startup. Run `swarmhub-herdr fleet-policy audit` as the bridge account to refresh the audit copy while it is serving. The journal copy has no authority over current generation. Keep the protected generation files when restoring a journal.

Each rule has an `id`, a safe `decision_ref`, `effective_ms`, `expires_ms`, a `scope`, and a `rule` with its `kind`. Scope matches action, project, owner and principal. Omitted fields match any value. A grant or named exception specifies an exact action and bot ID. Applicable STOP takes precedence. Any required project-owner sign-off must name the consenting owner and refer to the exact park revision. The operator records that sign-off in the signed policy with its decision reference. An eligible park-specific exception takes precedence over a general grant. Among grants the most specific scope wins, with rule ID breaking ties alphabetically. Revoked and expired rules confer no authority. An empty policy allows only an exact signed operator decision and grants no automatic execution.

### Filing and deciding a park

A registered owner uses `swarmhub-herdr bot park file ID -` to file manifest JSON and get its immutable pin. The current session can recover the manifest and receipt with `swarmhub-herdr bot park status ID`. The manifest names the owner, project, host, operation, artifact and adapter pins, expected old and new values, review, dry run and rollback plan. Use safe references in these fields. The fixture operation is `{"AdvanceStagingRef":{"reference":"refs/heads/staging","rollback":true}}`. The artifact pin is the new commit ID. The fixed apply and reverse pins are `builtin:git-update-ref:apply:v1` and `builtin:git-update-ref:reverse:v1`. The test enrollment pins the project, owner, host, operation, expected old ref and rollback plan. Completed review evidence pins the new commit and both adapter revisions.

Attention shows waiting and held parks. Approvals lists recent parks and opens their immutable pins, classification, decisions and receipts. Paste the signed decision object into the park's decision form. For supersession, paste `{"signed": …, "replacement": {"id": …, "manifest": …}}`. The authenticated `POST /api/parks/decide` endpoint takes a `park` with its ID and manifest digest, the `purpose`, and `evidence` as `{"signed": …}` or `{"imported": "NONCE"}`. A supersession also includes the replacement manifest and ID. Release returns a held revision to pending for a separate execution decision.

Jarvis submits signed JSON with `swarmhub-herdr bot park judge -`. The automatic backstop submits an `auto_execute` signature with `swarmhub-herdr bot park backstop -`. Its policy must contain an effective `safe_class_grant` for the exact project, `advance_staging_ref` action and delegate bot. A reviewed reversible staging update is eligible for delegation. Unknown actions, money, secrets, deletes and outside messages route to the operator. Project STOP and required partner consent apply before a grant or exception.

The journal records the classifier result, the decision basis and the matching v55 policy version with each state transition or claim. A nonce is consumed by the first recorded decision from that principal in the workspace. Retrying a claimed park can read the existing status or receipt. The effect check reads the protected policy again after claiming. Publication and the bounded effect use the same file lock so a completed revocation fences later execution. Git checks the expected old ref under its ref lock, and a separate read resolves the new value. An authorized rollback compares against the expected new value before restoring the old one.


### Review and repair budget

The review lineage starts with the successful managed author job ID. Each owner has one unresolved lineage per enrolled staging target. A later author job for the same owner and target shares that lock until a park verifies the lineage or the current owner closes it. Use `swarmhub-herdr bot job review abandon LINEAGE REASON` to record a closure after choosing to stop work, including after a denied park. The journal keeps the reason, owner, launch and time. An executing or unsettled park prevents closure. Closed evidence stays inspectable, and the same owner can start a fresh lineage with a new completed author job. The current owner uses `swarmhub-herdr bot job review -` to record the exact result bytes returned by `bot job result JOB REF`. Send a JSON command with `verb: "record"`, `job`, `attempt` and the result text encoded as the JSON string `artifact`. The bridge checks the result digest against the completed attempt and uses the worker's observed family, model, effort and CLI version. Model selection can be manual.

Every result contains `revisions` with `code`, `apply` and `reverse`, plus `tests` with an opaque `reference`, SHA-256 `digest` and positive `passed` count. Use `role: "author"` for the first result. A fixer result uses `role: "fixer"`, `lineage` and the reserved `round`. A reviewer result uses `role: "reviewer"`, `lineage`, `round` (zero for the first review), the current producer result's SHA-256 `producer_digest`, a `verdict` of `pass`, `concerns` or `changes`, and `findings` with a `severity` (`p0`–`p3`) and `summary` for each finding. A PASS has an empty findings list. The reviewer needs a known family different from the original author and current producer. A changed commit or wrapper requires fresh evidence for the new round.

To queue a repair, send `verb: "fix"`, `lineage`, `after_round` and `input` containing the normal managed submission JSON. The workspace reserves the round and queues one fix job in the same transaction. An exact retry returns the saved job. A reservation invalidates the previous round for execution, even when the next fix produces the same commit. After two automatic fixes and the final review, a further automatic request returns `escalate`. Reserve an explicitly approved extra round by including its named `exception`. `bot job review status LINEAGE` shows the current round and its recorded producer and reviewer evidence.

For a staging park, set `project` to the decimal managed-project ID, `review_ref` to the author job ID, and `dry_run_ref` to the current producer's test digest. Supersession preserves an active bound lineage. The signed decision and the effect check both require current evidence for the park's exact pins. CHANGES and P0/P1 findings hold the ref. P2-only CONCERNS can pass from round two under an active scoped grant. The claim records the evidence digests, policy revision and any exception used.

A review grant uses `kind: "review_exception"` with the exact `lineage` and `permission` (`"residual_p2"`, `{"extra_round":3}` for a specific additional round, or `"same_provider"`). Scope includes the exact `advance_staging_ref` action, project and owner. Each grant has a named decision reference and a finite effective interval. Same-provider permission is only relevant if the provider supplies distinct observed families, and a reviewer requesting it names the grant in `same_provider_exception`. The current fixture model mapping uses one family per provider. Grant expiry or revocation before the effect holds the park.

### Workload-bound Vault grants

The slice 12 fixture files a `UseWorkloadSecret` park for one admitted managed attempt. Its `grant_digest` is SHA-256 of compact JSON encoding the tuple `["swarmhub-workload-grant-v1", terms]`. The terms bind the opaque grant ID, job and attempt number, worker manifest digest, enrolled host ID and fingerprint, executable path and SHA-256, fixed argv, canonical working directory, Vault entry ID and revision, validity window, and use limit. Sign the exact park pin and current policy with the fixture operator key using purpose `authorize_workload`. The bridge records the grant, operator public-key fingerprint, nonce, and disposition in schema 58. Holding, denying or superseding the park revokes its recorded grant. The protected policy can also revoke the grant ID, and a policy generation change requires a newly signed authorization.

The Rust fixture starts a separate executor process with a private state root and two unnamed Unix sockets. The fixture controller provisions the runtime-generated value and local enrollment on a channel owned by the executor. The worker sends only the signed invocation on its separate inherited channel after checking the admitted attempt and its current lease. Frames use a four-byte big-endian size and up to 8192 bytes of JSON. The executor revalidates the consent under the protected policy lock, checks the recorded grant through a read-only fixture journal, verifies the actual host and command pins, and checks the current revision in its separate in-memory Vault. The value reaches the fixed command on stdin. The command's stdout and stderr are discarded. The reply is one of `denied`, `exhausted`, `uncertain`, `succeeded`, or `failed`.

The executor owns the separate schema-v1 SQLite ledger. It commits a reservation for the grant and invocation ID before crossing the command boundary. Both completed and unsettled reservations count against the limit. An unsettled invocation remains `uncertain` after restart and a replay of that ID never reruns the command. The fixture exposes a typed outcome through the worker and publishes no command-output artifact. Ordinary Vault session requests and repeated session grants carry no workload authority.

Commissioning still needs distinct worker and executor OS accounts, protected executor enrollment and storage, and a transport with authenticated peer identities. The same-account subprocess fixture exercises protocol separation. P0-07 remains open until private entry of new real material and separately recorded human consent for transfer of existing material are available. Real Core stdin execution (P2) and the worker Core socket's UID-only protection (P3) remain open.


### Staging an outbound draft

Open a suggested or previously downloaded email and choose **Stage for approval**. Enter the sending address, To, Cc, Bcc, subject, reply message ID and thread ID where applicable, and the plain-text body. Staging creates an immutable revision and a linked outside-message park. **Open approval preview** shows the full saved payload, its SHA-256 digest, and the park pin. The digest covers the channel tag and all payload fields in a fixed JSON order. CRLF in message bodies is stored as LF. Other Unicode text is preserved. The staged shape supports a single plain-text message and rejects extra headers and attachments.

Sign the preview's park pin and the current fleet policy using the operator key with purpose `authorize_outbound`. Submit the signed decision in Approvals. The journal preserves its envelope and signature for that revision. The same action applies to a deployment that transmits customer copy. Authenticated fixture clients can stage Slack, WhatsApp and deployment payloads at `POST /api/outbound/stage` with a project, a typed channel payload and version zero. To edit, pass the returned draft ID as `id` and the current version. Sending is disabled and this slice records no delivery attempt. Manual email delivery uses **Download .eml draft** or **Download staged .eml**.

Each staged edit gets a new park and its own decision. Editing supersedes a pending or held unclaimed park in the same journal transaction. An executing revision stays visible with its original payload alongside the new revision. The old decision remains in the audit history.

A text reviewer can post a group form using the exact `review_question` from the park preview as the form title. After the answer is recorded in the group, attach its group and answer IDs in Approvals, or use `POST /api/groups/{id}/outbound-text-review` with the `park` and `answer` IDs. The bridge keeps the question, answer and response scoped to that park. Delivery authorization comes from the separate signed operator decision.
