# P8b — Live end-to-end + on-screen launch

Read `PLAN.md`; standing constraints apply. Start from `main` AFTER P8a is merged. Branch `p8b`.

## 1. `AgentApp --e2e` (headless, real server, minimal and harmless)
Uses the exact UI code paths (AppStore send/steer/fork/model/group routing), never private shortcuts. All messages are
prefixed `[Torvli self-test — reply briefly, take no actions]` and go to NEW sessions created only for this test
(session ids prefixed `torvli-selftest-`), never to a bot's existing chat:
- a. Jarvis: send "Reply with exactly: E2E-CHAT"; expect reply containing it.
- b. Jarvis: send "Count slowly from 1 to 20, one number per line" and while it streams (after the first tokens) steer
  with "Stop counting and reply with exactly: E2E-STEER"; expect the steer accepted (HTTP 2xx) and the final text to
  contain E2E-STEER (if the model ignores it, report accepted-but-ignored, not failure).
- c. Fork the (a) session at its assistant message; send "Reply with exactly: E2E-FORK" in the fork; expect it.
- d. Model: read options; switch the (a) test session to a different available model, send "Reply with exactly:
  E2E-MODEL", confirm the session reports the new model, then switch back and confirm.
- e. Group: create a temporary group with DMT and Achilles; send "@DMT reply with exactly: E2E-GROUP"; expect only DMT
  answers; then delete the temporary group (the imported "Konrad, DMT, Achilles" group is not touched).
- f. Routines: list jobs on Jarvis (read-only).
Print one PASS/FAIL line per step with session ids; exit non-zero on any FAIL. Unit-test the step runner with the mock.

## 2. `--ui-smoke <report.json>` (real GUI, visible on Konrad's screen)
Launch the normal app UI; after the main window is on screen and the first Grok bot's chat has rendered, write a JSON
report from inside the app: window visible + frame, number of sidebar rows (bots + groups), selected bot, whether its
Grok history header shows the expected count, whether the Overview loaded skills (count) and Routines tab loaded
(state), and any errors shown. Then keep the app running normally (do NOT quit it — Konrad may use it).
No screenshots, no desktop automation, no AppleScript: the report comes from the app itself.

## 3. Run for real
Package + reinstall (signed; backup rule). Run `--e2e` with the installed binary, then
`open ~/Applications/Torvli.app --args --ui-smoke ~/Library/Caches/Torvli-snapshots/ui-smoke.json`, wait until the
file exists (≤90 s), and report its contents. Commit on `p8b` (author Konrad Sierzputowski <konrad@dmt.zone>); no push.
Final report: sha, test totals, every E2E line, the ui-smoke JSON.
