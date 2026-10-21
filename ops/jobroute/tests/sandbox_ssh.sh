#!/bin/bash
# Throwaway-sshd harness for jobroute. Runs ONLY inside the sandbox (see run-sandbox.sh):
#   sudo -u sbtest -- unshare -r -p -f --mount-proc bash sandbox_ssh.sh STAGE
# A test sshd runs in a nested user namespace as the unprivileged sbtest uid (no privsep, can
# only log in as sbtest), on 127.0.0.1, with throwaway host/client keys and an authorized_keys
# file using the production options string. The server itself ALLOWS pty, forwarding, agent
# and X11, so every refusal below comes from the key's options (restrict + command=).
# Processes are stopped by exact PID at the end; the pid namespace reaps anything left.
set -u
stage=$1
d=$stage/ssh
mkdir -p "$d/work/Admin" "$d/calls" "$d/home"
cd "$d" || exit 1
route=$stage/jobroute/jobroute
asuser() { unshare --user --map-user=1002 --map-group=1003 "$@"; }

for k in host admin ermes probe far; do ssh-keygen -q -t ed25519 -N '' -C "jobroute-test-$k" -f "$k"; done
cat > allowlist.toml <<EOF
[route]
state_dir = "$d/state"
sb_codejob = "$stage/jobroute/tests/stub-sb-codejob"
job_root = "$d/work"
[route.env]
STUB_RECORD = "$d/calls"
STUB_WORKROOT = "$d/work"
HOME = "$d/home"
[engines]
claude = ["claude", "-p"]
codex = ["codex", "exec", "--skip-git-repo-check", "-m", "gpt-6.1-sol", "-"]
[profiles.grok-admin]
agent = "Admin"
workdirs = ["$d/work/Admin"]
EOF
chmod 644 allowlist.toml
cmd() { echo "$route --config $d/allowlist.toml --profile $1"; }
# Production: restrict,from="195.201.33.222",command="..." ; here from= is the loopback address.
{
  echo "restrict,from=\"127.0.0.1\",command=\"$(cmd grok-admin)\" $(cat admin.pub)"
  echo "restrict,from=\"127.0.0.1\",command=\"$(cmd grok-ermes)\" $(cat ermes.pub)"
  echo "restrict,from=\"127.0.0.1\",command=\"/usr/bin/env\" $(cat probe.pub)"
  echo "restrict,from=\"10.9.9.9\",command=\"$(cmd grok-admin)\" $(cat far.pub)"
} > authorized_keys
port=$((20000 + RANDOM % 20000))
cat > sshd_config <<EOF
ListenAddress 127.0.0.1:$port
HostKey $d/host
AuthorizedKeysFile $d/authorized_keys
PidFile $d/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitTTY yes
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
AllowAgentForwarding yes
X11Forwarding yes
PermitTunnel yes
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF
asuser /usr/sbin/sshd -D -e -f "$d/sshd_config" 2> sshd.log &
for _ in $(seq 50); do grep -q "Server listening" sshd.log 2>/dev/null && break; sleep 0.1; done

SSH=(ssh -F /dev/null -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile="$d/kh"
     -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o LogLevel=ERROR)
c() { local key=$1; shift; asuser timeout 20 "${SSH[@]}" -i "$d/$key" sbtest@127.0.0.1 "$@"; }  # ssh reads options after the host
fails=0
check() {  # check NAME EXPECTATION-DESCRIPTION CONDITION-RESULT(0/1) EVIDENCE
  if [ "$3" = 0 ]; then printf 'PASS  %-34s %s\n' "$1" "$2"; else printf 'FAIL  %-34s %s\n      evidence: %s\n' "$1" "$2" "$4"; fails=$((fails+1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; echo $?; }
lacks() { grep -qF -- "$2" <<<"$1" && echo 1 || echo 0; }

out=$(printf 'Brief $(id) `id`;\n' | c admin 'submit engine=claude label=ssh-ok' 2>&1)
check ssh-submit-allowlisted 'ok + job_id over real ssh' "$(has "$out" '"ok": true')" "$out"
calls=$(ls "$d/calls"/*.stdin 2>/dev/null | wc -l)
check ssh-submit-brief-is-data 'stub got the brief byte-for-byte' "$( [ "$calls" = 1 ] && cmp -s "$(ls "$d/calls"/*.stdin)" <(printf 'Brief $(id) `id`;\n') ; echo $?)" "calls=$calls"
out=$(c admin status </dev/null 2>&1)
check ssh-status 'own job listed' "$(has "$out" 'ssh-ok')" "$out"
out=$(c ermes status </dev/null 2>&1)
check ssh-non-allowlisted-profile 'grok-ermes key refused' "$(has "$out" 'profile not allowlisted')" "$out"
out=$(c admin 'id' </dev/null 2>&1)
check ssh-shell-command 'requested "id" never runs' "$( [ "$(has "$out" 'unknown operation')" = 0 ] && [ "$(lacks "$out" 'uid=')" = 0 ]; echo $?)" "$out"
out=$(c admin 'submit engine=claude label=x; id' </dev/null 2>&1)
check ssh-shell-escape 'metacharacters refused' "$( [ "$(has "$out" 'command refused')" = 0 ] && [ "$(lacks "$out" 'uid=')" = 0 ]; echo $?)" "$out"
out=$(c admin -tt status </dev/null 2>&1)
check ssh-pty-route 'pty request refused' "$(has "$out" 'PTY allocation request failed')" "$out"
out=$(c probe -tt </dev/null 2>&1)
check ssh-pty-probe 'no SSH_TTY in session env' "$( [ "$(has "$out" 'PTY allocation request failed')" = 0 ] && [ "$(lacks "$out" 'SSH_TTY=')" = 0 ]; echo $?)" "$out"
out=$(c admin -N -o ExitOnForwardFailure=yes -R 127.0.0.1:0:127.0.0.1:"$port" </dev/null 2>&1); rc=$?
check ssh-remote-forward 'remote port forward refused' "$( [ $rc != 0 ] && [ "$(has "$out" 'forwarding failed')" = 0 ]; echo $?)" "rc=$rc $out"
out=$(c admin -W 127.0.0.1:"$port" </dev/null 2>&1); rc=$?
check ssh-local-forward 'direct-tcpip (-W/-L) refused' "$( [ $rc != 0 ] && grep -q 'refused local port forward' sshd.log; echo $?)" "rc=$rc $out"
out=$(c admin -N -o ExitOnForwardFailure=yes -R "$d/fwd.sock:127.0.0.1:$port" </dev/null 2>&1); rc=$?
check ssh-unix-socket-forward 'streamlocal forward refused' "$( [ $rc != 0 ] && [ ! -e "$d/fwd.sock" ]; echo $?)" "rc=$rc $out"
eval "$(asuser ssh-agent -s -a "$d/agent.sock")" >/dev/null
asuser ssh-add -q "$d/far" 2>/dev/null
out=$(SSH_AUTH_SOCK=$d/agent.sock c probe -A </dev/null 2>&1)
check ssh-agent-forward 'no SSH_AUTH_SOCK with -A' "$( [ "$(has "$out" 'PATH=')" = 0 ] && [ "$(lacks "$out" 'SSH_AUTH_SOCK=')" = 0 ]; echo $?)" "$out"
unset SSH_AUTH_SOCK
out=$(DISPLAY=:99 c probe -X </dev/null 2>&1)
check ssh-x11-forward 'no DISPLAY with -X' "$( [ "$(has "$out" 'PATH=')" = 0 ] && [ "$(lacks "$out" 'DISPLAY=')" = 0 ]; echo $?)" "$out"
out=$(asuser timeout 20 sftp -F /dev/null -P "$port" -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile="$d/kh" -i "$d/admin" -b - sbtest@127.0.0.1 <<<'ls /' 2>&1); rc=$?
check ssh-sftp-subsystem 'sftp subsystem refused' "$( [ $rc != 0 ]; echo $?)" "rc=$rc $(head -c 200 <<<"$out")"
out=$(c far status </dev/null 2>&1); rc=$?
check ssh-from-restriction 'key used from wrong address refused' "$( [ $rc = 255 ] && [ "$(has "$out" 'Permission denied')" = 0 ]; echo $?)" "rc=$rc $out"
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"submit_job","arguments":{"engine":"codex","label":"mcp-ssh","brief":"hi $(id)"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"job_status","arguments":{}}}' | c admin -T 2>&1)
check ssh-mcp-session 'MCP submit + status over ssh -T' "$( [ "$(has "$out" 'jobroute')" = 0 ] && [ "$(has "$out" 'mcp-ssh')" = 0 ] && [ "$(lacks "$out" '\"isError\": true')" = 0 ]; echo $?)" "$out"
n=$(grep -c '"op": "submit"' "$d/state/audit.jsonl")
check ssh-audit 'every submit audited with sha' "$( [ "$n" = 2 ] && [ "$(grep -c brief_sha256 "$d/state/audit.jsonl")" -ge 2 ]; echo $?)" "submits=$n"

[ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID"
[ -s "$d/sshd.pid" ] && kill "$(cat "$d/sshd.pid")"
echo "ssh harness: $fails failure(s)"
exit $((fails > 0))
