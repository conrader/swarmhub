# P13.0 box canary — result: NO-GO for sub-agent guidance (Part E)

2026-10-14 12:10–12:16 UTC, Konrad's box (Hermes 0.22.0 getermes build, layer 1.0.18), profile `grok-rapper`, run by the
orchestrator as user `hermes` (no restart, no Python from the core tree; core tree unchanged afterwards).
Pin set with `hermes -p grok-rapper config set delegation.provider openai-codex` + `delegation.model gpt-5.6-sol`
(read back with `config get delegation`), never `api_key`/`base_url`; numbered backup `/root/p13-canary-backup/grok-rapper.config.yaml.1`.
Two `torvli-selftest-p13canary-*` sessions; each asked the agent to delegate one trivial task (17*23) via `delegate_task`,
observed over `POST /p/grok-rapper/v1/runs` + `GET …/v1/runs/{id}/events`.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Child ran on the pin | **GO** | `subagent.start` and `subagent.complete` both carry `model: gpt-5.6-sol` (both runs), status completed, ~4–5 s, 2 API calls |
| 2 | How the result returns | **NO-GO** | Delegation is background (`{"status":"dispatched","mode":"background"}`). The result is persisted into the SAME profile session as a user-role row `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]`, but only once the parent turn has ended: delivery is retried ~8 times over ~15 s ("Session has an active turn lease") and then **terminally dropped** if the parent is still working. Run 1 (parent kept talking ~20 s after dispatch): result dropped, chat ends at "Waiting for the sub-agent result." Run 2 (parent ended its turn right after dispatch): result row delivered. |
| 3 | A parent locked to another model still gets pinned children | **GO** | Run 2's session was created locked to `openai-codex/gpt-5.6-terra`; the child still ran on `gpt-5.6-sol` |
| 4 | Model of the turn after the result | n/a | No turn follows: on API sessions the delivered row waits for the user's next message (no wake within 90 s) |
| 5 | Edit took effect without a restart | **GO** | `config set` then immediate runs used the pin; `NRestarts=0` throughout |
| 6 | Supplier accepted the id | **GO** (quota not measurable) | Codex accepted `gpt-5.6-sol`; each child used ~24.5k input / 40 output tokens on the shared ChatGPT window |
| 7 | Revert leaves nothing behind | **GO** | `config.yaml` restored from the backup, byte-identical (`cmp`), owner hermes 0600; `config get delegation` empty; `/p/grok-rapper` 200 |

**Verdict:** GO needs 1, 2, 3, 5, 6, 7 — check 2 fails, so `ModelRoles.subAgentGuidance` stays **false**; "Coding" means coding
threads only (P13 Part D, shipped). Part E does not start.

**What would turn 2 into GO:** Hermes delivering the async result after the parent turn ends instead of dropping it after ~15 s
(upstream 0.22.0 behaviour in `tools/async_delegation` / `gateway.run` delivery). Options for Konrad: report upstream, or carry a
getermes core patch that waits for the turn lease (fleet release decision), then re-run this canary.

Fixtures (shapes only): dispatch ack `{"status":"dispatched","mode":"background","count":1,"delegation_id":"deleg_…"}`;
delivered row: role `user`, content starts `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]`; run events `subagent.start` /
`subagent.complete` with keys `model, subagent_id, child_session_id, delegation_id, depth, task_count, status, duration_seconds,
api_calls, input_tokens, output_tokens`.
