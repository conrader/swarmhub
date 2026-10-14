# Runbook: set or remove a profile's sub-agent (delegation) model on a Hermes box

Only after a canary says GO (`docs/P13-canary.md` is NO-GO as of 2026-10-14). One profile first; the default profile last.
1. As root: `cp -a ~hermes/.hermes/profiles/<p>/config.yaml /root/<stamp>/<p>.config.yaml.<n>` (numbered backup).
2. Always as the hermes user (a root-run `config set` can leave a file the gateway cannot read):
   `sudo -u hermes env HERMES_HOME=/home/hermes/.hermes PYTHONDONTWRITEBYTECODE=1 hermes -p <p> config set delegation.provider '<slug>'`
   then the same with `delegation.model '<id>'` — always the pair; never `delegation.api_key` or `delegation.base_url`.
   The default profile has no `-p`.
3. Read back: `… hermes -p <p> config get delegation` (model and provider set); `ls -l` shows owner hermes, mode 0600.
4. No restart is needed. Check the profile still answers: `GET /p/<p>/v1/models` = 200 with its key.
5. Rollback: install the backup back as hermes 0600 and `cmp` it; `config get delegation` shows empty model/provider.
6. Never run Python from `/opt/hermes-core/releases/*` as root without `-B`; after any step `find <active core> -newermt <start>` must be empty.
