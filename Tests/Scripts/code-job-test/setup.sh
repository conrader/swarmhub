# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Setup: the copied scripts under a temp ROOT, the stub control interface, the CODE_JOB_TEST_LIMIT watchdog and the stub CLI.

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/code-job-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
# Exercise the shipped coding scripts in an isolated layout. Managed wake/worker integration is covered by sim/;
# starting persistent recovery workers for these standalone CLI cases races the temporary HOME cleanup.
mkdir -p "$ROOT/skills/swarmhub-coding/scripts" || exit 1
cp "$JOB" "$ROOT/skills/swarmhub-coding/scripts/code-job" || exit 1
cp "$(dirname "$JOB")/completion-contract.py" "$ROOT/skills/swarmhub-coding/scripts/completion-contract.py" || exit 1
cp "$(dirname "$JOB")/scratch.py" "$ROOT/skills/swarmhub-coding/scripts/scratch.py" || exit 1
cp "$(dirname "$JOB")/verify-sandbox.py" "$ROOT/skills/swarmhub-coding/scripts/verify-sandbox.py" || exit 1
cp "$(dirname "$JOB")/verify_darwin.py" "$ROOT/skills/swarmhub-coding/scripts/verify_darwin.py" || exit 1
cp "$(dirname "$JOB")/verify_git.py" "$ROOT/skills/swarmhub-coding/scripts/verify_git.py" || exit 1
cp "$(dirname "$JOB")/verify_processes.py" "$ROOT/skills/swarmhub-coding/scripts/verify_processes.py" || exit 1
cp "$(dirname "$JOB")/verify_signals.py" "$ROOT/skills/swarmhub-coding/scripts/verify_signals.py" || exit 1
JOB=$ROOT/skills/swarmhub-coding/scripts/code-job
# Claude Code only runs for a managed task (--task-id) that the control interface's check-job accepted. The real
# check-job (owner gate for claude orders) is covered by sim/test_fixes6_policy.py; this stand-in accepts the fixture
# task so the CLI-level behaviour of a managed claude run stays testable here. Cases opt in with `with_control`.
CTL_DIR=$ROOT/skills/swarmhub-messages/scripts
cat > "$ROOT/swarmctl-stub" <<'CTL'
#!/usr/bin/env python3
import sys
command, *args = sys.argv[1:]
if command in ("plan", "model"):
    print(args[0])
elif command != "check-job":
    sys.exit(64)
CTL
TASKID=task.0123456789abcdef0123456789abcdef
with_control() { mkdir -p "$CTL_DIR" && cp "$ROOT/swarmctl-stub" "$CTL_DIR/swarmctl"; }
PASSED=0 FAILED=0
# Signals name only a live descendant of this shell (an empty, garbage or recycled pid must not be signalled).
. "$(dirname "$0")/own-pid.sh" || exit 1
# CODE_JOB_TEST_LIMIT=<s>: a run still going after that long fails fast instead of holding the suite (a code-job under
# dash once sat ~20 min in a loaded full run). Past the limit, no case and no code-job invocation starts (job_to and
# case 24 check the flag), and until this shell exits the watchdog TERMs every running code-job (an own descendant
# whose command names this copy), then KILLs any still there 5 s later, and sweeps again: one that started just as the
# flag was set, or once KILL released the one before it, is stopped too. The shell exits only once a sweep finds none
# (or after 30 s more). The case cut short fails on its own checks, and the summary adds one FAIL.
over_limit() { [ -f "$ROOT/over-limit" ]; }
if [ -n "${CODE_JOB_TEST_LIMIT:-}" ]; then
  (
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$CODE_JOB_TEST_LIMIT" ]; do kill -0 $$ 2>/dev/null || exit 0; sleep 1; done
    : > "$ROOT/over-limit" || exit 0
    # The path travels in the environment: an awk argv naming it would list awk itself as a running code-job.
    # Deepest first (depth by the parent chain in the same listing): a code-job signalled before its own subshells
    # would orphan them, and an orphan fails own_pid, so it would be left running. Each pid is still checked with
    # own_pid right before its own signal; the order only keeps every one checkable.
    running() {
      ps -A -o pid= -o ppid= -o args= 2>/dev/null | J="$JOB" awk '{ parent[$1] = $2 } index($0, ENVIRON["J"]) { job[$1] = 1 }
        END { for (p in job) { d = 0; for (q = p; (q in parent) && d < 64; q = parent[q]) d++; print d, p } }' |
        sort -rn | awk '{ print $2 }'
    }
    owned() { for pid in $(running); do own_pid "$pid" "$JOB" && echo "$pid"; done; }
    while kill -0 $$ 2>/dev/null; do
      for pid in $(running); do own_pid "$pid" "$JOB" && kill -TERM "$pid" 2>/dev/null; done
      n=0; while [ -n "$(owned)" ] && [ $n -lt 5 ]; do sleep 1; n=$((n + 1)); done
      for pid in $(running); do own_pid "$pid" "$JOB" && kill -KILL "$pid" 2>/dev/null; done
      if [ -n "$(owned)" ]; then rm -f "$ROOT/swept"; else : > "$ROOT/swept"; fi
      sleep 1
    done
  ) < /dev/null > /dev/null 2>&1 &
fi
TASK='Fix the failing test in calc.py'
# Synthetic identities must reach both setup git and the CLI subprocess, even on
# a fresh Mac with no gitconfig. Ignore host signing/hooks/identity configuration.
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

cp "${CODE_JOB_STUB:-$(dirname "$0")/code-job-stub.sh}" "$ROOT/stub" || exit 1
