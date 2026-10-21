# jobroute: Hermes bots → sb-codejob on ovh

A restricted SSH route that lets an allowlisted Hermes profile do exactly two things on
ovh (145.239.94.119:49123, user `ubuntu`): **submit an sb-codejob job** and **read the
status of its own jobs**. It is our code and config only: a forced-command
`authorized_keys` line per profile pointing at `jobroute`. It uses no Hermes code; the
bots reach it through a stock `mcp_servers` entry (ssh stdio), the same way they already
reach the read-only SB MCP. It keeps working across Hermes updates because Hermes only
needs to be able to run `ssh` as an MCP command.

## Design

```
Hermes profile (user hermes @ 195.201.33.222)
  mcp_servers.jobs: ssh -T -i ~/.ssh/jobroute/<profile>_ed25519 -p 49123 ubuntu@145.239.94.119
        │  one key per profile
        ▼
ovh sshd → authorized_keys: restrict,from="195.201.33.222",command="…/jobroute --config … --profile <profile>"
        │  profile fixed by the key line; client cannot choose it
        ▼
jobroute  ── allowlist.toml (one file: profiles, agent, workdirs, engines, rate limits)
        │   validate → rate-limit (flock) → launch → audit.jsonl
        ▼
sb-codejob --agent <Agent> --workdir <dir> --label <label> --stdin -- <fixed engine argv>   (brief on stdin)
        └─ detached job; sb-codejob's existing wake route tells the agent when it ends
```

- **Identity.** The profile comes from the `authorized_keys` line, never from the client.
  A profile missing from `allowlist.toml` is refused even if its key is installed.
- **Two operations only.** The client controls just `SSH_ORIGINAL_COMMAND`:
  - empty or `mcp`: MCP over stdio with the tools `submit_job` and `job_status`;
  - `submit engine=E label=L [workdir=W] [agent=A]`, with the brief on stdin;
  - `status [job=ID] [limit=N]` / `list`, which return only this profile's own jobs;
  - `help`.

  Any other verb, key, repeated key, or token without `=` is refused, as is any character
  outside `[A-Za-z0-9 ._/=-]`. Nothing is passed to a shell: `sb-codejob` runs with a
  fixed argv list.
- **The brief is data.** It goes to the job on stdin, through `sb-codejob --stdin`. It is
  never placed in argv or a shell string. The limits: UTF-8, no NUL bytes, non-empty,
  64 KiB at most.
- **The engine is fixed.** The caller picks a name, `claude` or `codex`. The argv comes
  from `[engines]`:
  - `claude -p`;
  - `codex exec --skip-git-repo-check -m gpt-6.1-sol -`.

  `ANTHROPIC_API_KEY` is removed from the environment, so jobs use the subscription.
- **Validation.**
  - `agent` must match the profile's agent. Matching uses sb-codejob's own
    normalisation, which ignores case, spaces and hyphens.
  - `label` must match `[A-Za-z0-9][A-Za-z0-9_-]{0,39}`.
  - `workdir` must be the profile's root or an existing subdirectory of it. Components
    must match `[A-Za-z0-9][A-Za-z0-9._-]*`, and `..` is rejected. The `realpath` must
    stay inside the root, so a symlink that escapes it is refused.
- **Rate limit (per profile).**
  - At most 4 accepted submissions per hour and 20 per day.
  - At most 2 route jobs running at once.
  - The check and the launch run under one `flock`.
  - Exceeding a limit exits with code 3 and is logged as `rate_limited`.
- **Audit.** `~/.local/state/jobroute/audit.jsonl` (mode 600) gets one JSON line for every
  submit, status call, parse refusal and refused profile. Each line records `ts`,
  `profile`, `op`, `mode`, `result`, `reason`, `peer`, `label`, `engine`, `workdir`,
  `brief_sha256` and `brief_bytes`. The brief itself is never logged.
  `profiles/<profile>.jsonl` is the list of that profile's own jobs, which `status` reads.
- **Defence in depth.**
  - The route refuses to run if `allowlist.toml` or the state directory is not owned by
    `ubuntu`, or is group- or world-writable.
  - The CLI mode has a 120 s alarm.
  - MCP lines over 1 MiB are drained and dropped.
  - `#!/usr/bin/python3 -IB` ignores `PYTHON*` environment variables and the user site,
    and writes no `.pyc` files.
- **What it does not limit.** A job is a full `claude`/`codex` run as `ubuntu` on ovh.
  On ovh, `~/.codex/config.toml` sets `sandbox_mode = "danger-full-access"`. So the
  route controls who can launch a job, how often, with which engine, and where it starts.
  It does not control what the brief asks the job to do. Claude `-p` with no permission
  flags gets ovh's default permissions. Edits and Bash then need a prompt that `-p`
  mode cannot answer, unless ovh's `~/.claude/settings.json` allows them. Whether to add
  `--permission-mode acceptEdits` to the claude engine is one line in
  `allowlist.toml`; that is Jarvis's decision.
- **Known limit: key binding.** All profiles run as unix user `hermes`. Each key file is
  mode 600, but any `hermes` process could read another profile's key. Per-profile
  identity holds as long as bots have no file-read or shell tool, which is the case
  today. If they gain one, the route is still limited to the 12 allowlisted profiles,
  still rate-limited, and still audited.

## Files

| file | purpose |
|---|---|
| `jobroute` | entry point: forced-command args, strict CLI, MCP stdio server |
| `jobroute_core.py` | allowlist loading, validation, rate limit, audit, submit, status |
| `allowlist.toml` | the one config file (12 profiles) |
| `tests/test_jobroute.py` | pytest: wrapper called with `SSH_ORIGINAL_COMMAND` (stub sb-codejob), plus one run against a copy of the real sb-codejob with a stub engine |
| `tests/sandbox_ssh.sh` | throwaway sshd in the sandbox: real ssh client against the production options string |
| `tests/run-sandbox.sh` | runs both, each as `sudo -u sbtest -- unshare -r -p -f --mount-proc …` |

Run the tests on ovh as `ubuntu`: `ops/jobroute/tests/run-sandbox.sh`.

## Keys (Infra): one ed25519 key per profile

The private key is created on the Hermes box, where it is used. It is copied only into
sb-vault, through a pipe, and is never printed. Run this from ovh as `ubuntu`:

```bash
PROFILES="grok-achilles grok-admin grok-boppy grok-botsilo grok-dmt grok-doc grok-finance-controller grok-infra grok-plainsay grok-rapper grok-saldora grok-vised"
HERMES="ssh -o BatchMode=yes -i /home/ubuntu/.ssh/hetzner_operator_ed25519 root@195.201.33.222"

# 1. generate on the Hermes box (owner hermes, dir 700, key 600); never overwrite
$HERMES "install -d -o hermes -g hermes -m 700 /home/hermes/.ssh/jobroute && for p in $PROFILES; do
  k=/home/hermes/.ssh/jobroute/\${p}_ed25519; [ -e \"\$k\" ] && { echo \"exists \$k\"; continue; }
  sudo -u hermes ssh-keygen -q -t ed25519 -N '' -C \"jobroute:\$p\" -f \"\$k\"; done"

# 2. store each private key in sb-vault (stdin only; nothing echoed)
for p in $PROFILES; do
  $HERMES cat "/home/hermes/.ssh/jobroute/${p}_ed25519" \
    | sb-vault put "auto/hermes/jobroute/$p" --purpose "SSH key for Hermes profile $p -> ovh jobroute (sb-codejob submit/status only). Lives at /home/hermes/.ssh/jobroute/${p}_ed25519 on 195.201.33.222."
  sb-vault mark "auto/hermes/jobroute/$p" --no-handover
done

# 3. authorized_keys on ovh (THE PROD STEP: parked for sb-approve, see Install)
cp -p ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-jobroute-$(date -u +%Y%m%dT%H%M%SZ)
for p in $PROFILES; do
  pub=$($HERMES cat "/home/hermes/.ssh/jobroute/${p}_ed25519.pub")
  case "$pub" in "ssh-ed25519 "*" jobroute:$p") ;; *) echo "unexpected pubkey for $p"; exit 1;; esac
  printf 'restrict,from="195.201.33.222",command="/home/ubuntu/.local/lib/jobroute/current/jobroute --config /home/ubuntu/.config/jobroute/allowlist.toml --profile %s" %s\n' "$p" "$pub" >> ~/.ssh/authorized_keys
done
```

Every line uses this exact options string:

```
restrict,from="195.201.33.222",command="/home/ubuntu/.local/lib/jobroute/current/jobroute --config /home/ubuntu/.config/jobroute/allowlist.toml --profile <profile>"
```

`restrict` turns off pty, port, agent and X11 forwarding and `~/.ssh/rc`. `from=` pins the
key to the Hermes box. `command=` is the only thing the key can run.

## Hermes profile config (after approval and the live test; no SOUL change here)

The profile references the key **by path only**. Key material is never in `config.yaml`,
the environment, a prompt or a log. The ovh host key is already pinned in
`/home/hermes/.ssh/known_hosts` for the SB MCP entry.

```bash
sudo -u hermes -H hermes -p <profile> mcp add jobs --command ssh --args -T \
  -i /home/hermes/.ssh/jobroute/<profile>_ed25519 -p 49123 \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/home/hermes/.ssh/known_hosts -o ServerAliveInterval=30 \
  ubuntu@145.239.94.119
sudo -u hermes -H hermes -p <profile> mcp test jobs
```

The bot then sees two tools: `submit_job {engine, label, brief, workdir?}` and
`job_status {job_id?, limit?}`.

## Install on ovh (prod: parked for Jarvis's sb-approve; pin `SHA`)

```bash
set -euo pipefail
SHA=<pinned commit>                       # the PR head commit
REL=/home/ubuntu/.local/lib/jobroute/releases/$SHA
tmp=$(mktemp -d); git clone -q git@github.com:conrader/swarmhub.git "$tmp/r"
git -C "$tmp/r" cat-file -e "$SHA^{commit}"
mkdir -p "$REL"; git -C "$tmp/r" archive "$SHA" ops/jobroute | tar -x -C "$REL" --strip-components=2
(cd "$REL" && sha256sum jobroute jobroute_core.py allowlist.toml)   # compare with the pinned file hashes
chmod -R go-w "$REL"; rm -rf "$tmp"
install -d -m 755 /home/ubuntu/.config/jobroute
[ -e /home/ubuntu/.config/jobroute/allowlist.toml ] || install -m 644 "$REL/allowlist.toml" /home/ubuntu/.config/jobroute/allowlist.toml
ln -sfn "$REL" /home/ubuntu/.local/lib/jobroute/current
# self-check (read-only apart from creating the state dir and one audit line)
SSH_ORIGINAL_COMMAND=help /home/ubuntu/.local/lib/jobroute/current/jobroute --config /home/ubuntu/.config/jobroute/allowlist.toml --profile grok-admin
SSH_ORIGINAL_COMMAND=help /home/ubuntu/.local/lib/jobroute/current/jobroute --config /home/ubuntu/.config/jobroute/allowlist.toml --profile grok-ermes; echo "exit $? (expect 2)"
# then Infra step 3 (authorized_keys), then the Hermes config for ONE profile, then the live test
```

No systemd unit, no sb service and no sshd config changes. `sshd` reads `authorized_keys`
on each connection.

## Rollback

```bash
# 1. cut access at once: drop the jobroute key lines (each ends in " jobroute:<profile>")
cp -p ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-pre-rollback-$(date -u +%s)
grep -v ' jobroute:grok-[a-z-]*$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new
diff ~/.ssh/authorized_keys ~/.ssh/authorized_keys.new || true      # only jobroute lines may differ
install -m 600 ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys && rm ~/.ssh/authorized_keys.new
# (or restore ~/.ssh/authorized_keys.bak-jobroute-<ts> from Infra step 3)
# 2. Hermes: sudo -u hermes -H hermes -p <profile> mcp remove jobs      (per profile that had it)
# 3. optional: rm /home/ubuntu/.local/lib/jobroute/current
```

Jobs that are already running are detached sb-codejob jobs. Rollback does not stop them,
and they still wake their agent when they end. Keys stay in sb-vault and on the Hermes box
until someone decides to remove them; deleting a secret is Konrad's call.
