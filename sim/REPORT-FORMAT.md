# Results and evidence contract

`results.json` records schema, UTC run ID/time, source commit, host/mode, safety test counts, catalog SHA-256, source findings and one result per selected QA ID. `live_app_executed` means at least one acknowledged app action; `uncertain_live_scope` records attempted scope creation without acknowledged actions. A false execution flag alone does not rule out an uncertain begin; inspect both. Offline has both false.

Per-result fields: ID/title, bounded variant, status, reason, source Grok comparison, coverage, uncovered branches, assertion details when available, scope creation attempted/action counts for live attempts, and halt marker if cleanup or safety fails. Separate evidence files retain native screenshots by receipt/ID, ordered events, actual remote session/profile/run/task/job/approval identifiers when available, exact marked prompts, tool/sandbox receipts, duplicate counts and usage deltas. Screenshot paths from the hook are evidence identifiers, never input paths to open or execute automatically. `actions.jsonl` is a sanitized runner journal; tokens and arbitrary server response bodies are excluded.

| Status | Meaning |
| --- | --- |
| `pass` | All implemented assertions for this **bounded variant** passed with authoritative complete observations. Full scenario remains partial when branches are uncovered. |
| `bug` | At least one bounded-variant oracle failed with valid evidence. Retain repro, raw receipts and native state before promoting to a confirmed app issue. |
| `fail` | Reserved for runner/infrastructure failures where a test result can be established; self-test errors also produce exit 1. |
| `blocked` | Missing environment, unsafe connector, absent capability, incomplete evidence, uncertain acknowledgement, observation timeout or unconfirmed cleanup. Never an app pass or app bug by itself. |

`coverage:partial` means a client recipe covers only named safe branches. `coverage:design-only` means no safe executable adapter is supplied. All 65 current runtime results are blocked; none establishes whole-plan acceptance. B scenarios must ultimately be run separately per supported real backend; the present client is Hermes-only under this brief. Mobile needs its own adapter. Overnight/restart/DST/fault branches remain explicit follow-up work.

Source probes have independent `source-confirmed` / `needs-review` statuses and always `runtime_reproduced:false`. These probes assert only text patterns in the reviewed commit. A matching pattern neither executes Swift nor proves timing, line ordering or user impact; the report's manual source review supplies the concrete hypothesis. The 14 entries correspond to known QA findings, not 14 newly reproduced bugs.

Grok labels are the supplied QA baseline: `matches / worse / missing / better`. “Matches” refers to the stated mechanism or feedback principle; it never invents undocumented Grok UI behavior. Combined cases retain their detailed qualifications in `qa_script` (e.g. F20 skills match but background memory is worse; A05 time scheduling exists but precise windows/recovery are worse). No comparative runtime test or “better” claim was performed.

For each confirmed bug, retain: commit/build/server versions, scenario and branch, exact actions/marked prompts, expected vs actual outcome, independent event/receipt/screenshot evidence, duplicate count, usage delta, cleanup receipt, and smallest safe repro. Use separate entries for product gaps, source risks, environment blockers and live regressions.
