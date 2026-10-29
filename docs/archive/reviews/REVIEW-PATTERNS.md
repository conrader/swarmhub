# Review: d233afb + c88ce2f (held/priority delivery, P01–P10 managed runtime)

Reviewer: Claude Fable 5.1, 2026-10-19. Read PEER-REPORT.md and PATTERNS-REPORT.md first.
No code was edited or committed. All paths are relative to the repo root; `S/` =
`Resources/Skills`.

## Verdict: **ship-with-fixes**

Fix 1–3 before deploying to a box with real coordinator/owner profiles. 4–5 before
relying on the queue unattended. The rest can follow.

## What was verified

- Tests run here: `python3 -B -m unittest discover -s sim -p 'test_*.py'` → 87 OK.
  `Tests/Scripts/code-job-test.sh` → 15/15 under `sh` and `dash`.
  `Tests/Scripts/bot-msg-test.sh` → 14/14 (sockets work in this sandbox, unlike
  the report's). `git diff --check` clean. Swift tests **not compiled** (no Swift here).
- Hermes server code: **nothing changed.** Every file in both commits is under
  `Resources/Skills`, `Sources/AgentApp`, `Tests`, `sim` or the two reports. The plugin
  is written to `<profile>/plugins/swarmhub-peer/` (Hermes' documented user plugin dir)
  and only imports `hermes_constants`. Hook names and kwargs match Hermes 0.20.5
  (`agent/turn_context.py:1236`, `agent/turn_finalizer.py:623`); `post_llm_call` fires
  only with a final, uninterrupted response, consistent with "no answer → stays pending".
- Credentials: `.env` is read only in `bot-msg` (lines 72–81, 229) and handed to curl
  on stdin. `swarmctl register` checks the file exists and returns a reference string
  (`swarm_control.py:96–102`); `status` prints id/gate/status/error only. Nothing
  prints or copies a key.
- FAKE outbound: `tick` marks it done with `FAKE: no outbound operation executed` and
  never spawns argv (`swarm_control.py:501–502`); P09 test covers it. Real outbound
  needs the coordinator (`validate_spec`, line 243). Owner gate for money/prod/secrets/
  provision/non-allowlisted reads (line 241). Denials persist by intent and operation
  fingerprint (lines 253–255, 291).
- Exit-65 contract: `code-job:270–278` fails when model/report are missing, the CLI
  returned 0 with empty output, or the report is missing/empty/unchanged versus the
  pre-run hash (`completion-contract.py`). `claude --effort/--model` and
  `codex -c/--model` are accepted by the CLIs installed on this box.
- Warsaw window: probed `reporting_targets` at 07:59/08:00/22:59/23:00 on 2026-10-19,
  on the 2026-03-29 DST day, and in January/July. Owner included exactly in
  [08:00, 23:00) local time.

## Findings

1. **HIGH — receiver receipts bind by session, not by delivery id; a foreign turn
   acknowledges a delivery that was never sent.** `swarm_control.py:393–402`
   (`receipt_bind`/`receipt_ack` match on `(target, session, turn)`), called from
   `peer-runtime.py:86,126`. Any ordinary `bot-msg --priority` from the same sender to
   the same target during a durable delivery's window binds to the running receipt and
   marks it `received`. Reproduced in a scratch HOME: claim → unrelated turn → status
   `received`; `deliver()` then returns 0 with no send. Loses coding-completion wakes
   and durable messages silently. Fix: prefix every delivered text with
   `[SwarmHub delivery id=<ident>]` (completion wakes already carry the job id), pass
   `user_message` through the hook lambda (`peer-runtime.py:236`), and in `receipt_bind`
   only bind the receipt whose id appears in that message. Add a regression for the
   interleaved ordinary send.

2. **HIGH — held batch (32,000 chars) exceeds Hermes' hook-output spill threshold
   (10,000), so large batches are marked delivered but mostly unseen.**
   `peer-runtime.py:105–109` builds up to 32,000 chars; Hermes
   `tools/hook_output_spill.py:54` spills `pre_llm_call` context over 10,000 chars to a
   file and injects a 500-char head/tail preview. `after_turn` (`peer-runtime.py:129`)
   then marks the whole claim delivered. Fix: cap the batch (including the policy
   prefix) at ~9,000 chars, or read `hooks.output_spill.max_chars` from the Hermes
   config; keep the overflow queued. Add a test with two 8,000-char messages.

3. **MEDIUM — `fake: true` is accepted but ignored for every kind except outbound.**
   `swarm_control.py:203–205` validates the flag for all kinds; `tick` honours it only
   for outbound (`501`). Reproduced: a `read` with `fake: true` executed its argv
   (`done`, `exit 0`). An owner approving a "fake" `provision`/`prod`/`secrets` action as
   a dry run gets a real execution. Fix: in `validate_spec` raise `ValueError("fake is
   only valid for outbound")` when `fake` is set on another kind, or make `tick` treat
   every `fake` spec as a FAKE no-op. Test both.

4. **MEDIUM — the recovery worker dies on any unexpected exception and nothing
   restarts it.** `peer-runtime.py:216–223` calls `retry_once()` and
   `control.retry_deliveries()` unguarded; `retry_once` catches only
   `OSError/ValueError/TimeoutExpired` (line 191), `retry_deliveries` only `ValueError`
   (`swarm_control.py:438`). A `sqlite3.OperationalError` (lock held >10 s) or a
   malformed record file kills the loop; the flock is released and the queue stalls
   until the next startup path. Fix: wrap each sweep in `except Exception`, write the
   error to `job-wake.error`, sleep with backoff, continue.

5. **MEDIUM — approval actor is a caller-supplied argv string.** `swarmctl:32–37` →
   `swarm_control.py:286–288` compares `actor` with the policy's owner/coordinator
   name; any bot's shell can run `swarmctl decide <id> owner approve`. The reports
   label this a trusted local interface and the SKILL forbids impersonation, which is a
   prompt-level control only. Fix: derive the actor from the invoking gateway
   (`HERMES_HOME` basename or `HERMES_SESSION_ID`) and reject a mismatch; record
   actor, pid and timestamp in the action row so a bypass is at least auditable.

6. **LOW — PID reuse confuses liveness.** `swarm_control.py:464–466,476–479` and
   `process_alive` (571–573) test only that some process has the pid. A recycled pid
   keeps a cancelled scope "busy" forever or never fails a lost running job. Fix: store
   `ps -o lstart=` with the pid at spawn and compare both.

7. **LOW — a policy-only turn is told held messages were delivered.**
   `peer-runtime.py:113–120` always appends "Held peer messages delivered with this
   turn" even when `batch` is empty (reproduced). Fix: emit that paragraph only when
   `batch` is non-empty.

8. **LOW — `check_job` re-resolves policy at job start.** `swarm_control.py:347–351`
   compares the launched parameters against `coding_model`/`coding_plan` evaluated now.
   A `route`/`codex_model` change between `tick` and `code-job` start fails the job
   with "parameters do not match" and holds the bot's queue. Fix: store the resolved
   order/model on the action row at launch and compare against that.

9. **LOW — "empty work" check reads stdout+stderr combined.** `code-job:~200,275`:
   `$T/out` is fed by both `tee` pipes, so a CLI that prints only warnings passes
   `[ -s "$T/out" ]`. Fix: tee stdout additionally into `$T/stdout` and test that.

10. **LOW — file-size rule.** `swarm_control.py` is 573 lines (project rule ≤500).
    Fix: move receipts/deliveries (lines 354–447) into `swarm_delivery.py`.

11. **INFO — report claims to re-check.** PEER-REPORT says `bot-msg-test.sh` could not
    run; it runs here (14/14). `code-job-test.sh` labels the dash run "under /bin/sh"
    and leaves its temp dir behind on exit (cosmetic).

## Not verified

Swift compilation and the native UI chips; live Hermes plugin activation on a running
gateway; real Codex/Claude runs (stub CLIs only); behaviour on macOS `sh`/`ps`.
