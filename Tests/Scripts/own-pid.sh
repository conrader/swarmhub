# Sourced by the shell suites that signal pids (code-job-test.sh, bot-msg-test.sh); see sim/ISOLATION.md.
#
# own_pid PID [ARG]: true only when PID is a plain number above 1, not this shell, a live descendant of this shell
# by the parent chain ps reports now, and (given ARG) its command line contains ARG. A pid read from disk or a `$!`
# whose job was already reaped may name an unrelated process by now; neither passes, so nothing is signalled.
own_pid() {
  case $1 in ''|*[!0-9]*|0|1|0*) return 1 ;; esac
  [ "$1" != $$ ] || return 1
  _own_at=$1 _own_hops=0
  while [ "$_own_hops" -lt 64 ]; do
    _own_at=$(ps -o ppid= -p "$_own_at" 2>/dev/null | tr -d ' ')
    [ "$_own_at" = $$ ] && break  # Before the <= 1 check: this shell is pid 1 of an `unshare -p -f` namespace.
    case $_own_at in ''|*[!0-9]*|0|1) return 1 ;; esac
    _own_hops=$((_own_hops + 1))
  done
  [ "$_own_at" = $$ ] || return 1
  [ -n "${2:-}" ] || return 0
  case $(ps -o args= -p "$1" 2>/dev/null) in *"$2"*) return 0 ;; esac
  return 1
}
