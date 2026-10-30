Third fix pass on the per-bot approvals feature, per docs/REVIEW-approvals-fix2.md (Claude re-review of fix2, verdict PASS-WITH-ISSUES with 3 must-fix items). Work only in this repo and against fixtures or the throwaway Hermes on this Mac (never Konrad's servers). Never push, never run git add/commit (.git is read-only for you; Ermes commits), never install anything outside this repo. Build on HEAD (fix2 work is uncommitted dirty on top of 6b76da3 / prior checkpoint — keep that tree; do not reset).

Must-fix (details and file:line refs in docs/REVIEW-approvals-fix2.md):
1. T1 (HIGH for test gate): change TestBackend.StreamMode.approvalThenFinish command at Tests/AgentAppTests/AgentAppTests.swift:29 from "cmd" to a reviewable command such as `cat /tmp/x`, so the three reviewer tests reach the reviewer again (`ownerStopCancelsAndStopsInFlightReviewer`, `reviewerEscalationFallsBackToUser`, `reviewerApprovalRequestEscalatesAndSelfReviewIsGuarded`). Confirm ask-mode `approvalIsScopedAndClearedAtRunEnd` still passes.
2. N9 (HIGH if confirmed): refuse automatic allow when the command contains a redaction marker (`...`, `***`, `[REDACTED]`, `<redacted>`). Optionally confirm from throwaway Hermes v0.21.7 `_redact_approval_command` what it can mask and note it in README. Add a test that a redacted-looking command is not auto-allowed.
3. N2r (MEDIUM, must-fix part): delete the default `read*`/`*` preset, or replace it with a real command pattern so a `read*` action kind cannot auto-allow `/bin/rm -rf …`.

Strongly recommended if cheap:
- N4r: capture the reviewer StopTarget while the stream is live (like AppStore.stop does) so owner Stop and nested-approval actually POST stop; add a TestBackend mode that clears the target on cancel.
- N2r extras: block `rg --pre` and `git --output` / `git log|diff --output=`; reword BotEditorView hint to say "a short list of known-dangerous programs/options" not a complete reject.

List any you don't fix in README "Known issues" (N3r, N8 side effect, remaining denylist gaps).

Then ./scripts/build.sh, try swift test (save docs/approvals-fix3-*.log with the exact command; if still blocked by _XPCTypeBool, say so), run the fixture script (EPERM in sandbox is acceptable; report honestly), and package into dist/ without installing. Print a per-item summary (done / not done / unverified), the dist path and its SHA-256.
