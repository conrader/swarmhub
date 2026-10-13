New feature for AgentApp: per-bot approval modes. Work only in this repo and against fixtures or the throwaway Hermes on this Mac (never Konrad's servers). Never push, never run git add/commit (.git is read-only for you; Ermes commits), never install anything outside this repo. HEAD is 751be18 (Hermes integration done).

0. Housekeeping first: add a short "Known issues" section to README.md listing the LOW findings from docs/REVIEW-hermes-fix5.md that fix6 did not close, plus: swift test cannot run on this Mac (Xcode 16.2 _XPCTypeBool toolchain break), fixtures pass when run outside the Codex sandbox (docs/hermes-fix6-fixtures-ermes.log), live throwaway Hermes reached profiles but reports version "unknown (degraded)" and has no model provider (docs/hermes-fix6-live-ermes.log).

1. Approvals, per bot, chosen in the bot's settings/info pane:
   - Ask me (current behaviour, default).
   - Auto-approve by rules: an ordered rule list per bot (match on tool/action kind and command or argument pattern; outcome allow, deny, or ask). Ship sensible presets, e.g. reads allowed, sends and deletes always ask. No rule match means ask.
   - Reviewer bot: hand the decision to another chosen bot in the app, which answers approve, deny, or escalate; escalate, timeout, or reviewer error falls back to asking the user. Never let a bot review itself; guard against loops.
2. Audit log: every approval request and its outcome (who decided: user, rule id, or reviewer bot, plus reason and timestamp), persisted locally and visible per bot (right panel or info pane). Never log secrets; reuse Hermes command redaction.
3. Works for both Mock and Hermes backends; a Hermes approval resolved by a rule or reviewer must still send the correct {choice, request_id} to the right run.
4. Tests for rule matching, reviewer fallback/escalation, self-review guard, and audit persistence; a fixture run proving an auto-approved and an escalated Hermes approval.

Then ./scripts/build.sh, try swift test (save docs/approvals-*.log; report honestly if blocked), run the fixture script, package into dist/ without installing. Print a per-item summary (done / not done / unverified), dist path and SHA-256.
