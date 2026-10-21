# Changelog

## Unreleased

- New Hermes and OpenClaw bots receive only Swarm Hub's read-only default connectors (SB and the optional `default-connectors.json` policy). Creation uses a fresh stock backend profile/workspace instead of cloning a manager's config, `.env`, auth files or workspace. Non-default manager connectors and their credentials are never copied during creation. Model/provider authentication may need to be configured separately.
- Other manager connectors are explicitly opt-in for one bot through the connector config helper. The selected connector and its credentials are copied only into that bot's private config; unrelated connectors and credentials remain on the manager. Default aliases retain their read-only policy.
- Migration: existing bots keep every connector they already have. Updating the app or manager skill does not remove, disable or narrow any existing bot's connectors. Retrying provisioning on a previously provisioned bot also preserves subsequent opt-ins. Review existing holdings with the read-only audit before deciding on any manual cleanup.
- Added an offline-capable connector audit. See [connector configuration](connectors.md). No Hermes code changes or release are required.
