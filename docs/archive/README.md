# Archive

Historical working documents, including the 2026-10-29 archive and the scoped
2026-11-11 root cleanup. They describe jobs and source state at the time they
were written; task instructions and deployment claims here are not current.

Use the [project overview](../../README.md), [roadmap and limits](../ROADMAP-AND-LIMITS.md),
[feature status](../FEATURES.md) and current runbooks under [docs](../).

- `briefs/` — historical job briefs. The separate root `briefs/` directory remains in place.
- `reports/` — historical job and verification reports; tests apply to their recorded baseline/environment.
- `reviews/` — historical reviews of particular revisions. Top-level `docs/REVIEW-*` remain in place.
- `plans/` — superseded plans and accepted architecture decision records; their old phase states are not a current backlog.

## Added in the 2026-11-11 P0/P1 cleanup

- [backlog1](reports/backlog1-report.md), [backlog2](reports/backlog2-report.md), [fix round 2b](reports/fixround2b-report.md).
- [PLAN](plans/PLAN.md), [CORE-PLAN](plans/CORE-PLAN.md), [CORE-PHASES](plans/CORE-PHASES.md).
- [KNOWN-GAPS](reports/KNOWN-GAPS.md): the accepted ancestry exception remains a living limitation.
- [Original jobroute two-command/shared-account design](plans/jobroute-shared-account-design.md): obsolete activation examples, preserved for history only.

Files keep their original names where moved; `git log --follow` shows their
history. Newly moved files identify their original location and baseline and
have repaired Markdown links. Older archived files may still refer to missing
job-local logs, external worktrees or source `path:line` locations; those are
historical references, not current runbook links.
