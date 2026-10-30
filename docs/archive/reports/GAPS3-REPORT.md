# Gaps3 result

2026-10-19. **Gaps 2 and 3 implemented; gap 1 remains blocked in this sandbox. Live pass 6 is not ready.**
Changes remain in the worktree. No Hermes changes, real outbound sends, provisioning, deployments, gateway
restarts, CLI installations/replacements or worktree commits occurred.

1. **Nested CLI:** `sim/live_cli.py` now creates user-owned 0700 runtime and temporary directories under the
   private temporary `CODEX_HOME`, and passes `XDG_RUNTIME_DIR`/`TMPDIR` to coding children. Existing auth/config
   remain referenced by symlink; source contents were checked unchanged. This is **not a proven closure**:
   two real jobs (installed CLI 0.162.1 and the pass-5 CLI 0.163.0, `gpt-6-astra`/`high`) still fail their tools
   with the same bubblewrap socket-directory error. Both CLI processes exit 0; unchanged shipped `code-job`
   correctly exits **65**, with **report-valid=false**, verification not run and no fabricated artifacts.
   Jobs used disposable git repositories and an isolated copy of the shipped runner/helper with no messaging
   sibling, so no wake could reach Hermes. See [0.163.0 evidence](../../../sim/results/gaps3/QA-cli-smoke.json),
   [0.162.1 evidence](../../../sim/results/gaps3/QA-cli-preflight-smoke.json) and
   [reproduction script](../../../sim/results/gaps3/QA-cli-reproduce.py).
   A [standalone sandbox probe](../../../sim/results/gaps3/QA-sandbox-probe.json), with zero provider calls, reproduces
   the error with all three private directories at 0700. The default `/tmp/codex-daemon-1000` is visible as mode
   **000** inside the outer sandbox; this appears to be the remaining obstacle. No shared socket directory or
   sandbox protection was altered. Successful file edit + command + accepted fresh report remains unproven;
   it needs a compatible outer runtime/socket environment before replay. One initial smoke setup failed before
   CLI execution because its isolated copy lacked the completion helper; the helper was then copied unchanged.

2. **Model-to-app contract:** bundled messaging instructions now show exact, valid approval and secret-request
   fences and explicitly require their delimiters. Shared Swift extraction additionally accepts one whole-reply
   bare JSON object through the **unchanged field guards and sanitizers**. Prose containing JSON, generic `json`
   fences, bare arrays and malformed/invalid required fields remain rejected. **43 shared fixtures** run through
   a Python mirror and a new native Swift test, including the actual pass-5 replies: P07's bare approval is
   accepted; P06's prose-embedded secret request still needs the corrected prompt. Messaging skill/plugin
   metadata is **1.3.3**, so the app can offer an update; nothing was installed into Hermes.

3. **Receipt wording:** configured verification that did not execute now says “verification configured but not
   run” and identifies the command. Empty/missing configuration still says “no verification command configured”.
   A regression checks both states.

Validation:

- `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **128 passed, 0 failed, 0 skipped**
  ([log](../../../sim/results/gaps3/QA-python-tests.txt)); includes four new regressions and the 43 parser fixture cases.
- `bot-msg` socket suite: **14 passed under sh + 14 under dash**, zero failures/skips
  ([sh](../../../sim/results/gaps3/QA-bot-msg-sh.txt), [dash](../../../sim/results/gaps3/QA-bot-msg-dash.txt)).
- `git diff --check`: passed. Real CLI acceptance: **0 passed / 2 failed jobs** as retained above.
- Swift compilation/tests and native approval-card/secret-sheet interaction remain **untested** (Swift absent).
  Python fixtures do not certify native behavior. Model compliance with the revised instructions and the full
  P01–P10 pass 6 were not rerun. Deployed autonomous integration remains outside this brief's test boundary.
