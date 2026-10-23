# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 17-23: evidence (commits, the verification command), verification cleanup and report states.

# 17
case_17() {
new_case "fresh report and output but no commit and no verification: unverified (66)" codex; mode codex ok
CASE_VERIFY=; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 66 (got $RC)" [ "$RC" -eq 66 ]
expect "report was written" [ -s "$C/work/REPORT.txt" ]
expect "unverified reason on stderr" has "$C/err" "code-job: unverified: fresh report but no new commit and no passing verification"
expect "status unverified" [ "$(rec status)" = unverified ]
expect "evidence none" [ "$(rec evidence)" = none ]
expect "tests not-run" [ "$(rec tests-passed)" = not-run ]
expect "verify mode - when nothing ran" [ "$(rec verify-mode)" = - ]
expect "not a repo" [ "$(rec commit-evidence)" = not-a-repo ]
expect "report-valid true" [ "$(rec report-valid)" = true ]
expect "cli-exit 0" [ "$(rec cli-exit)" = 0 ]
expect "log exit 66" [ "$(field 7)" = 66 ]
line_matches '^code-job: codex unverified · ' "summary line"
done_case
}

# 18
case_18() {
new_case "a failing verification command is recorded and fails the job (66)" codex; mode codex ok
CASE_VERIFY='exit 3'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 66 (got $RC)" [ "$RC" -eq 66 ]
expect "verify exit 3" [ "$(rec verify-exit)" = 3 ]
expect "tests false" [ "$(rec tests-passed)" = false ]
expect "verify command recorded" [ "$(rec verify-command)" = 'exit 3' ]
expect "evidence none" [ "$(rec evidence)" = none ]
expect "verify exit on stderr" has "$C/err" "(verify exit 3)"
# An unavailable verifier must still fail closed (the macOS /bin/true failure).
# Keep the missing executable in the allowed workspace: this tests ENOENT (127),
# not a sandbox refusal to inspect an executable outside it (126 on macOS sh).
CASE_VERIFY='./missing-verifier'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "missing verification: 66 (got $RC)" [ "$RC" -eq 66 ]
expect "missing verify exit 127" [ "$(rec verify-exit)" = 127 ]
expect "missing verify tests false" [ "$(rec tests-passed)" = false ]
expect "missing verify evidence none" [ "$(rec evidence)" = none ]
done_case
}

# 19
case_19() {
new_case "a new commit in --dir is evidence (ok) and a failing verification outweighs it" codex; mode codex commit
if git_repo "$C/work"; then
  before=$(git -C "$C/work" rev-parse HEAD)
  CASE_VERIFY=; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
  expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
  expect "evidence commit" [ "$(rec evidence)" = commit ]
  expect "commit-evidence true" [ "$(rec commit-evidence)" = true ]
  expect "head-before recorded" [ "$(rec head-before)" = "$before" ]
  expect "head moved" [ "$(rec head-after)" = "$(git -C "$C/work" rev-parse HEAD)" ] && [ "$(rec head-after)" != "$before" ]
  expect "tests not-run" [ "$(rec tests-passed)" = not-run ]
  line_matches '^code-job: codex ok · ' "summary line"
  CASE_VERIFY='exit 5'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
  expect "commit plus failing verification: 66 (got $RC)" [ "$RC" -eq 66 ]
  expect "commit still recorded" [ "$(rec commit-evidence)" = true ]
  expect "evidence none" [ "$(rec evidence)" = none ]
else
  PROBLEMS="$PROBLEMS; git fixture initialization failed (commit evidence not exercised)"
fi
done_case
}

# 20
case_20() {
new_case "a passing verification command run by code-job in --dir is evidence (ok)" codex; mode codex ok
CASE_VERIFY='test -s REPORT.txt && pwd -P > verify.pwd'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "evidence tests" [ "$(rec evidence)" = tests ]
expect "tests true" [ "$(rec tests-passed)" = true ]
expect "verify exit 0" [ "$(rec verify-exit)" = 0 ]
expect "verify ran in --dir" [ "$(cat "$C/work/verify.pwd")" = "$(cd "$C/work" && pwd -P)" ]
expect "no verify output kept" [ ! -f "$C/home/.hermes/swarmhub/job-completions/verify" ]
# The launcher's isolation mode is part of the record (fixes7): a known word, written out of the verifier's reach.
vm=$(rec verify-mode)
case $vm in namespaced|fallback|seatbelt) ;; *) PROBLEMS="$PROBLEMS; verify mode recorded (got '$vm')" ;; esac
[ "$vm" = fallback ] && expect "limited mode said on stderr" has "$C/err" "verification ran in the limited sandbox"
[ "$vm" = fallback ] || expect "no limited-mode line when namespaced" lacks "$C/err" "limited sandbox"
mode codex quiet
CASE_VERIFY='true'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "empty work still 65 before any evidence (got $RC)" [ "$RC" -eq 65 ]
expect "evidence not collected" [ "$(rec evidence)" = none ] && [ "$(rec tests-passed)" = not-run ]
done_case
}

# 21
case_21() {
new_case "verification cannot remove the required report and still certify done" codex; mode codex ok
CASE_VERIFY='rm REPORT.txt'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "report invalid after verification" [ "$(rec report-valid)" = false ]
expect "verification did run" [ "$(rec tests-passed)" = true ]
done_case
}

# 22
case_22() {
new_case "interrupting verification kills its child process" codex; mode codex ok
# The verifier runs in its own PID namespace on Linux, so its `$!` means nothing to the host. Give its executable
# a case-specific path: the Swift suite runs sh and dash concurrently, and either one's sleeper must never count
# as the other's readiness or survivor. Keep matching after reparenting too; an ancestry-only check would hide leaks.
# Zombies print as <defunct> and do not match.
ln -s /bin/sleep "$C/work/verification-sleeper"
sleepers() { ps -A -o args= 2>/dev/null | grep -Fxc -- "$C/work/verification-sleeper 59.37"; }
CASE_VERIFY="\"$C/work/verification-sleeper\" 59.37 & wait"; job --bot jarvis --order codex --dir "$C/work" -- "$TASK" &
runner=$!
i=0; while [ "$(sleepers)" -eq 0 ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "verification started" [ "$(sleepers)" -gt 0 ]
pid=$(cat "$C/home/.hermes/swarmhub/job-completions/"job.*/pid 2>/dev/null)
own_pid "$pid" "$JOB" && kill -TERM "$pid"
wait "$runner"; RC=$?; unset CASE_VERIFY
expect "exit 143 (got $RC)" [ "$RC" -eq 143 ]
i=0; while [ "$(sleepers)" -gt 0 ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
expect "verification child gone" [ "$(sleepers)" -eq 0 ]
expect "job interrupted" [ "$(rec status)" = interrupted ]
done_case
}

# 23
case_23() {
new_case "fallback through a symlinked parent: the physical report counts; an empty or unreadable one is 65, named" codex
# The Mac cj-home layout: --dir is HOME reached through a symlink, so launcher scratch falls back to /tmp and codex
# gets both tmp exclusions; the CLI writes the report at the physical path code-job hands it.
ln -s "$C/home" "$C/homelink"; P=$(cd "$C/home" && pwd -P)
mode codex ok
job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
expect "ok: exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "ok: report at the physical path" [ "$(rec report)" = "$P/REPORT.txt" ]
expect "ok: codex ran in the physical dir" [ "$(cat "$C/state/codex.pwd")" = "$P" ]
expect "ok: fallback /tmp exclusion" has "$C/state/codex.args" "sandbox_workspace_write.exclude_slash_tmp=true"
expect "ok: fallback TMPDIR exclusion" has "$C/state/codex.args" "sandbox_workspace_write.exclude_tmpdir_env_var=true"
expect "ok: report checked and kept" [ "$(rec report-valid)|$(rec report-state)|$(rec report-final)" = "true|ok|nonempty" ]
# mac-smoke3-533593b recorded exactly this: report-exists=true, report-sha256=missing-or-empty, exit 65.
mode codex emptyreport
job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
expect "empty: exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "empty: the Mac record" [ "$(rec report-exists)|$(rec report-sha256)|$(rec report-valid)" = "true|missing-or-empty|false" ]
expect "empty: named at check and finish" [ "$(rec report-state)|$(rec report-bytes)|$(rec report-final)" = "empty|0|empty" ]
# A report python3 cannot read is not "missing" (Python 3.14 folded such stat errors into is_file() == False).
if [ "$(id -u)" -ne 0 ]; then
  mode codex lockedreport
  job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
  chmod 600 "$C/home/REPORT.txt"
  expect "unreadable: exit 65 (got $RC)" [ "$RC" -eq 65 ]
  expect "unreadable: named, the shell still sees it" [ "$(rec report-state)|$(rec report-valid)|$(rec report-final)" = "unreadable-EACCES|false|nonempty" ]
fi
done_case
}
