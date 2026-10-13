Fourth pass on the Hermes integration, per docs/REVIEW-hermes-fix3.md (Claude re-review of FIX3, verdict PASS-WITH-ISSUES, no blockers). Work only in this repo and against the throwaway Hermes on this Mac (never Konrad's servers). Never push, never install anything outside this repo.

Step 0 (checkpoint): commit the current reviewed FIX3 tree locally on the current branch: sources, tests, Tests/Fixtures, docs, scripts, README. Leave BRIEF-*.md untracked. Message: "Hermes integration (fix3, Claude PASS-WITH-ISSUES)". Do not commit anything after this step.

Then fix on top (leave uncommitted for review):
1. F6: disable Approve (or require an explicit confirm) when an approval event has no command text; show that the command is unknown.
2. A single Stop must produce one message: no extra "cancelled" error banner when Stop lands during a bot's first turn.
3. Run-id race: a cancelled old run must never clear a newer run's id (guard by the per-run token).
4. Give the server Stop request a short timeout (5–10 s); a late confirmation must not attach to a later turn.
5. F4: when history merge refuses (divergence, truncated reply after Stop), show a quiet note instead of doing nothing silently.
6. Tests: add a failed-old-Stop vs newer-run test and a history paging cap test; replace fixed sleeps with deterministic waits where cheap. Try hard to run `swift test` / xcodebuild test without sudo or system changes; if still blocked by _XPCTypeBool/CoreDevice, say exactly why and save the output under docs/.
7. Docs: README and docs/hermes-integration.md must state plainly whether tests have ever executed, and drop or back up the "type-checks" claim with a saved log.

Then ./scripts/build.sh, repeat the native/legacy fixture checks and the live throwaway-Hermes check (provider auth may fail honestly). Finally package a release .app zipped into dist/ (ad-hoc signed is fine) ready for a later MacBook install, without installing it. Print a per-item summary (done / not done / unverified), the checkpoint commit hash, and the dist path.
