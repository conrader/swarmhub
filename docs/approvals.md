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

Fleet policy is a fixture for durable decisions about immutable parks. The initial operation is `set_revision_marker` in a disposable project. The provider permission prompt still uses the interactive approval flow above. The fleet authority check accepts an operator decision or a registered bot's signed request. Browser access, bot display names, the main-bot flag, group form answers and chat quotes supply no fleet decision evidence.

The bridge and operator commands use the deployment's `SWARMHUB_FLEET_POLICY_DIR`, `SWARMHUB_FLEET_OPERATOR_UID` and `SWARMHUB_FLEET_WORKSPACE`. Provision the directory under a distinct, non-root operator account and give the bridge read access. Use a stable absolute path without symlinks or writable parents controlled by the bridge, and on macOS use an ACL-free directory and ancestry. Provision an operator-owned, empty `policy.lock` and an operator-owned `trust.json` with `workspace`, `operator_key` and optional `delegate` containing `bot_id` and `key`. The bridge expects the configured workspace ID and operator ownership. Public keys are standard padded Base64 of 32 raw Ed25519 bytes. Keep the operator signing key under the operator identity. Delegated execution requires a separately protected Jarvis signer with its own key because agent terminals share an OS account. An unavailable trust boundary or signer holds the request.

All input to the following commands is JSON on standard input.

- `swarmhub-herdr fleet-policy digest` reads a policy containing `generation`, `rules` and `revoked` and prints its generation and SHA-256 digest. Generations start at 1. Each publication advances by one, and revoked rule IDs carry forward.
- `swarmhub-herdr fleet-policy payload` reads an envelope and emits the exact UTF-8 bytes for signing. The first line is `swarmhub-fleet-decision-v1`. The JSON on the next line is compact and has no trailing newline. Fields are `workspace`, `principal`, `purpose`, `target`, `nonce`, `issued_ms`, and `expires_ms`. An operator principal is `{"kind":"operator"}`. A bot principal has `kind:"bot"`, stable `id` and current `launch`.
- For `publish_policy`, use a target with `kind:"policy"` and `policy` set to the generation and digest. For a park decision use `kind:"park"`, the same `policy` reference and a `park` with `id`, `revision` and `manifest_digest`. Park purposes are `execute`, `release`, `hold` and `deny`. The delegated signer can sign only `execute`. Times are Unix milliseconds, and the end of an interval is exclusive.
- Sign offline. On the operator account, `swarmhub-herdr fleet-policy import-policy` reads `{"policy": …, "signed": {"envelope": …, "signature": …}}`. `swarmhub-herdr fleet-policy import-decision` reads the signed object and returns its nonce. Encode the raw Ed25519 signature with standard padded Base64. Exact retries are safe. Key enrollment and signing take place outside the bridge.
- `swarmhub-herdr fleet-policy inspect` and the authenticated `GET /api/bots/fleet-policy` show the trusted current policy. The bridge copies published generations to schema v55 on startup. Run `swarmhub-herdr fleet-policy audit` as the bridge account to refresh the audit copy while it is serving. The journal copy has no authority over current generation. Keep the protected generation files when restoring a journal.

Each rule has an `id`, a safe `decision_ref`, `effective_ms`, `expires_ms`, a `scope`, and a `rule` with its `kind`. Scope matches action, project, owner and principal. Omitted fields match any value. A grant or named exception specifies an exact action and bot ID. Applicable STOP takes precedence. Any required project-owner sign-off must name the consenting owner and refer to the exact park revision. The operator records that sign-off in the signed policy with its decision reference. An eligible park-specific exception takes precedence over a general grant. Among grants the most specific scope wins, with rule ID breaking ties alphabetically. Revoked and expired rules confer no authority. An empty policy allows only an exact signed operator decision and grants no automatic execution.

The fixture effect check reopens the protected store and compares both policy generation and digest before invoking the adapter. Publication and the bounded effect share a file lock so a completed revocation fences later execution. This slice exposes policy inspection and local imports. The managed park decision entry point is added in slice 5.
