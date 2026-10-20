# P5d Mac regression checks

Baseline: `b821501`; P5d base: `b3a5617`. Validation ran offline on Linux with
`PYTHONDONTWRITEBYTECODE=1`. Swift is unavailable; a Mac Swift rerun is still needed.

The origin failure is a parser bug. The rejected input in the existing test is
`https://box.invalid:0444`, which Foundation normalizes to `:444` before the old
validator sees it. The contract requires canonical decimal ports: `:444` is valid,
`:0444` is not. The shared Swift adapter now checks the raw spelling first, keeping
the existing mixed-case host and connection-path support. The Python box already
rejects leading-zero ports. A shared 24-case fixture checks the Swift wire, Python
box and reference validator; additional box tests verify rejection without writes.
The original protocol and signature fixtures are unchanged. Messages skill 1.4.5
clarifies the existing Python rule, with version pins updated.

P01/P02 failed at their eight-second readiness deadline while the full Mac suite
ran concurrently. Comparing base to HEAD shows no changes to `sim/test_patterns.py`,
`sim/test_peer_runtime.py`, `ObservedPatternTests.swift`, `swarmhub-coding`, or
`swarm_jobs.py`. The P5d box changes concern approval modes and one additional
SQLite table; they do not change coding-job execution or readiness publication.
The evidence points to scheduling/startup delays on the loaded Mac, rather than a
P5d job-runtime regression. Linux cannot reproduce or certify Mac scheduling.

The shared test wait now polls the same predicate until a fixed 30-second monotonic
deadline, returning immediately when ready. All queue, evidence, delivery and
deduplication assertions remain. Deterministic tests cover completion after the old
limit, a hung predicate failing at 30 seconds, immediate readiness, and propagation
of predicate errors. Ten concurrent offline replay processes using the Swift
launch environment also all returned `matches` (zero model calls).

| Requested check | Actual result |
| --- | --- |
| `sim/test_patterns.py` | 18 passed |
| `scripts/test_ios_approval_boundary.py` | 15 passed |
| `scripts/test_mac_device_approvals.py` | 52 passed |
| `sim/test_device_approvals.py` | 54 run: 53 passed, 1 socket-permission error |
| `sim/test_remote_approvals.py` | 11 passed |
| `sim/test_device_enrollment.py` | 10 passed |
| `sim/test_device_security_regressions.py` | 9 passed |
| `sim/test_fixes8_skills.py` | 2 passed |
| `python3 -m unittest discover -s scripts` | 361 run: 356 passed, 4 socket-permission errors, 1 macOS-only skip |
| `python3 -m unittest discover -s Tests/Updater` | 26 passed |
| `bot-msg-test.sh` under sh | Exit 77, 0 cases: loopback socket permission denied |
| `bot-msg-test.sh` under dash | Exit 77, 0 cases: loopback socket permission denied |
| `git diff --check` | Passed |

Additional checks: `sim/test_peer_runtime.py` passed 13 tests; the four deadline
regressions passed (also included in scripts discovery). All changed source files
are at most 500 lines. No Hermes source was changed. The socket errors are from
the sandbox denying `socket()` with EPERM: one device HTTP test and four Grok
exporter HTTP tests. Their assertions and skip behavior were left intact.
