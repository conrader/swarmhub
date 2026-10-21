# Connector configuration

Swarm Hub ships `Resources/Skills/swarmhub-manager/scripts/default-connectors.py` with the manager skill. The examples below use that checkout path; an installed Hermes manager uses `~/.hermes/profiles/<manager>/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py` (or `~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py` for the default manager). Older installations receive the current helper at `~/.config/swarmhub/default-connectors.py` during new-bot creation.

New bots receive SB's forced-command read-only wiki connector and the optional read-only defaults in `~/.config/swarmhub/default-connectors.json`. Additional defaults remain filtered references to their original source; their credentials are never copied. Aliases, unreadable sources and refused HTTP defaults retain the behavior established in PR #5. OpenClaw's new workspace has no MCPorter imports.

Use the manager's normal approved creation flow. The helper's `create hermes <bot> --description '<description>'` or `create openclaw <bot>` calls the stock backend CLI without copying a manager profile/workspace. Both refuse existing directories. A fresh Hermes profile uses the stock model configuration; configure model/provider authentication separately if needed. Never restore a manager's entire `.env`, auth files, config or credential-bearing skills to recover authentication.

The helper creates a temporary `.swarmhub-new-bot` marker in the freshly created directory and provisions defaults immediately. `provision <backend> <bot>` only completes that pending creation; after success it returns the saved setup report without changing connectors. It refuses an unmarked legacy bot. No startup migration rewrites existing bots.

To opt one existing bot into one other manager connector, explicitly select both names:

```sh
python3 Resources/Skills/swarmhub-manager/scripts/default-connectors.py opt-in hermes reports --manager manager --connector finance
python3 Resources/Skills/swarmhub-manager/scripts/default-connectors.py opt-in openclaw reports --manager manager --connector finance
```

This copies only `finance` from the manager's `mcp_servers` (Hermes) or workspace `config/mcporter.json` `mcpServers` (OpenClaw). Inline `env`, headers, command and arguments are copied. `$VAR` and `${VAR}` references are resolved from the process environment and the backend and manager `.env` files, with the manager file taking precedence; only values referenced by that connector enter the target config. Missing variables fail before changing the bot. Standard unquoted, single-quoted, double-quoted and `export KEY=value` dotenv lines are supported; shell evaluation and multiline dotenv values are not supported. External credential files remain references to their existing paths. Target configs and provenance files are written with mode 0600.

The command refuses an existing target connector, the manager itself, the default bot, directory symlinks, default connector names, and aliased source names of defaults from that manager. It does not broaden defaults or overwrite an existing connection. It returns a status report without credentials. Other bots and manager files are unchanged.

Read-only inventory of existing non-default holdings:

```sh
python3 Resources/Skills/swarmhub-manager/scripts/default-connectors.py audit hermes
python3 Resources/Skills/swarmhub-manager/scripts/default-connectors.py audit openclaw
```

`--home /path/to/fixture-home` before `audit` targets an offline fixture tree. The JSON lists `bot`, `connector`, `source`, `config` and `origin_known`. Explicit opt-ins record their manager config as source. For legacy holdings the original manager is unknown, so source identifies the bot config containing the connector and `origin_known` is false. Hermes includes the default profile and named profiles; OpenClaw scans standard `workspace-<bot>` directories. Custom workspace paths must be inventoried separately. Imported MCPorter catalogs are flagged for review without opening them or displaying their potentially sensitive import strings.

The audit reads configs, the defaults policy and provenance only. It never invokes a backend, discovers tools, reads secret values into its output, or changes any file. An unreadable or malformed config fails with exit 1 and a fixed error instead of silently omitting a bot. The regression tests run it only on synthetic homes; do not run it against live Hermes for this change.
