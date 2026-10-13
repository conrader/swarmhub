Final closing pass on the per-bot approvals feature, per docs/REVIEW-approvals-fix3.md (Claude re-review of fix3, verdict PASS-WITH-ISSUES). This ends the review loop: keep it small. Work only in this repo and against fixtures or the throwaway Hermes on this Mac (never Konrad's servers). Never push, never run git add/commit (.git is read-only for you; Ermes commits), never install anything outside this repo. HEAD is ad8504d (fix3 committed); build on it.

Do:
1. F1 (MEDIUM): on store load, migrate saved bots: remove any legacy allow rule whose action-kind pattern is `read*` with command pattern `*` (the old default preset), and log it in the audit log as a migration. Add a test that a store saved with the legacy rule no longer auto-allows `/bin/rm -rf /tmp/x` for a `read_file` action kind after load.
2. F2 (LOW-MEDIUM): make the Stop test assert the captured run (`run-1`) was the one stopped, not just that a stop call happened.
3. README: update "Known issues" to list the remaining LOWs from the review (stop target not captured before first event; timeout sends two stop requests; cancelled reviewer run can count as approval; misleading audit reasons) plus anything you didn't fix; point log references at approvals-fix4-* instead of approvals-fix-*.

Optional only if trivial: the cancelled-reviewer-run-counts-as-approval LOW (a cancelled reviewer run must never count as approval).

Then ./scripts/build.sh, try swift test (save docs/approvals-fix4-*.log; if still blocked by _XPCTypeBool, say so), run the fixture script (EPERM in sandbox is acceptable; report honestly), and package into dist/ without installing. Print a per-item summary (done / not done / unverified), the dist path and its SHA-256.
