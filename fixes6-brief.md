Fix job for Swarm Hub branch swarmhub/peer-delivery (this checkout, HEAD 7f4c2fb). Read REVIEW-CLAUDE-XREV.md first (verdict: block) and REVIEW-CODEX-3.md for background.

Fix, each with regression tests:
1. Finding 1 (BLOCKER): verifier sandbox must not be able to write the repo's .git (config, hooks, fsmonitor, anything git later executes) on Linux or macOS. Add a test reproducing the core.fsmonitor escape and proving it now fails. Also make sure a later host `git status` cannot execute verifier-planted config.
2. Finding 2: Linux verifier sandbox must let ordinary test commands work (writing /dev/null, git starting, node child processes, Python asyncio/multiprocessing/subprocess timeouts) without weakening finding 1. Add tests running a small real pytest-style and node child-process check under the sandbox.
3. Finding 3: narrow the macOS sandbox profile's broad mach/system-service grants to what the verifier needs (no pasteboard, no LaunchServices URL opening). Make the deny tests runnable natively on Darwin (not text-only) so we can run them on the MacBook next; note the exact command to run there.
4. Finding 4: coding jobs must require owner approval by default (no gate=auto default), and `--order claude` must not get an unsandboxed host shell without that approval. Pick the safer design; document it.
5. Findings 6-8: exercise the real ManagedLocalControl / swarmctl path in at least one end-to-end approval test (fake outbound only); show all fingerprinted spec fields on the approval card; restore evidence requirements for plain `/goal` where it changes code, or document why not.
Do NOT change finding 5 (remote-box approvals) or finding 9; leave them for the owner's decision and just note current behaviour.

Hard rules: never alter Hermes; only the Swarm Hub app and its own scripts/skills. All test outbound stays fake/stubbed; no live Hermes/provider calls. No Swift toolchain here: keep Swift changes compile-safe (no nested #require/#expect macros) and list Swift tests to run on the Mac.
Run the Python suite under sim/ and the code-job shell suite (sh and dash) and report results.
Commit your work on this branch with clear messages (git identity is configured), and write FIXES6-REPORT.md: what changed per finding, file:line, tests run and results, and what still needs a real-Mac run.
