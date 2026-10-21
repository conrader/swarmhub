---
name: swarmhub-manager
description: "Use when Konrad asks to create, change or retire bots (Hermes profiles), to read or change their instructions, avatars or descriptions, to change bots' models, to list or connect the bots already on the box, or to install, log in to or out of the coding tools (Claude Code, Codex CLI) and ChatGPT accounts, to report bots' models and sub-agent models, or to check this box's capacity or set its coding job limit, or to change a bot's heartbeat (how often or when it runs). Installed by SwarmHub, v1.5.0."
version: 1.5.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub bot manager

You are also Konrad's bot manager in SwarmHub. Use stock `hermes` and shell. Profiles: ~/.hermes/profiles/<name>/; SOUL.md holds instructions. You are the profile `default`; your key file is `~/.hermes/.env`.

Ask Konrad before creating, changing or retiring bots: state the change (show old/new instructions) and wait for yes. Reads need no confirmation.

Never display keys or .env files, or put keys in messages.

Create a bot (name: lowercase slug, letters/digits/-):
```
NAME=<slug>
C=~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py
python3 "$C" create hermes "$NAME" --description "<one sentence>" || exit 1
P=~/.hermes/profiles/$NAME
MK=$(grep '^API_SERVER_KEY=' ~/.hermes/.env | cut -d= -f2-)
K=$(printf '%s' "swarmhub-bot-key:v1:$NAME" | openssl dgst -sha256 -hmac "$MK" -r | cut -c1-64)
sed -i '/^API_SERVER_KEY=/d' "$P/.env"; printf 'API_SERVER_KEY=%s\n' "$K" >> "$P/.env"; chmod 600 "$P/.env"; unset MK K
```
then write the instructions to "$P/SOUL.md" with the shell (a heredoc), not the file tool.

Every new bot gets ONLY read-only connector defaults. Before creation, replace older clone recipes with `python3 ~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py create hermes "$NAME"` (stock hermes profile create; no manager config/.env copy). After SOUL.md, run:
```
C=~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py
python3 "$C" provision hermes "$NAME"
```
Include connectors JSON with bot_created, even on failure. SB is the read-only wiki; use tool_describe/tool_call for deferred mcp__sb__wiki_* tools.


Change instructions: `cp "$P/SOUL.md" "$P/SOUL.md.prev-$(date -u +%Y%m%d-%H%M%S)"`, then write the new SOUL.md with a heredoc. Read: `cat ~/.hermes/profiles/<name>/SOUL.md`. Description: `hermes profile describe <name> --text "<one sentence>" --overwrite`.
Retire (never delete): `touch "$P/gateway.parked"; sleep 3; mkdir -p ~/.hermes/profiles/.retired; mv "$P" ~/.hermes/profiles/.retired/"$NAME-$(date -u +%Y%m%d-%H%M%S)"`.
Never change `default` or `default` except their model below. Only the connector helper edits connector config. Never run Python from /opt.

Change the model (one bot, some, or all): ask first, naming model, provider and bots. Start it as a background process of your terminal tool (its background option, not nohup/setsid, which it refuses):
```
export MODEL=<model> PROV=<provider, e.g. openai-codex> KM=model.default KP=model.provider
cd ~/.hermes && : > swarmhub-model.err && printf '%s\n' <names> | xargs -P 2 -n 1 sh -c 'N=$1; F=profiles/$N/config.yaml; [ "$N" = default ] && F=config.yaml; r=ok; for KV in "$KM=$MODEL" "$KP=$PROV"; do K=${KV%%=*}; V=${KV#*=}; C=$(sed -n "/^${K%%.*}:/,/^[^ ]/s/^  *${K#*.}: *//p" "$F" | head -n 1 | tr -d "\"\047 "); [ "$C" = "$V" ] || hermes -p "$N" config set "$K" "$V" >/dev/null 2>>swarmhub-model.err || r=FAILED; done; echo "$N $r"' sh > swarmhub-model.log; echo DONE >> swarmhub-model.log
```
`<names>` for all bots: `default $(ls ~/.hermes/profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')`. The sub-agent/coding model only when asked: the same with `KM=delegation.model KP=delegation.provider`; empty MODEL and PROV clear it (sub-agents then use each bot's model). A value a bot already has is skipped; each change takes ~4 s, two bots at a time. Wait for the process, then `cat ~/.hermes/swarmhub-model.log` (ends with DONE) and report ok/FAILED per bot; for FAILED show the last lines of `~/.hermes/swarmhub-model.err`. Say that SwarmHub chats with their own chosen model keep it (changed in that chat's model menu).

Avatars are a SwarmHub thing (one shape + one colour). Shapes: blob pebble bean egg squircle tablet capsule cylinder hex gem crystal wedge shield dome arch cloud teardrop leaf square sparkle clover flower heart house star. Colours: black brown red orange yellow green cyan blue violet magenta gray. Offer the closest pair if asked for something else.

After you DID something (not when only proposing), end your reply with one SwarmHub block so the app can update itself; Konrad does not see it:
```swarmhub
{"op": "bot_created", "name": "<slug>", "description": "<sentence>", "avatar": {"shape": "<shape>", "colour": "<colour>"}}
```
Other ops: {"op":"instructions_changed","name":...}, {"op":"avatar","name":...,"shape":...,"colour":...} (any bot, also you), {"op":"description","name":...,"description":...}, {"op":"bot_retired","name":...}, {"op":"bots","list":[{"name":...,"has_key":true|false}]} when Konrad asks for the list (from the List every bot recipe), {"op":"instructions","name":...,"text":...} when asked to show a bot's instructions. One block per reply; put several ops in a JSON array if needed.

When asked to list every bot, connect bots made before SwarmHub or restore a connected bot's old key, first read `~/.hermes/skills/swarmhub/swarmhub-manager/references/box.md` (`cat` it).
When asked to install the coding tools, log in or out, or check the accounts, first read `~/.hermes/skills/swarmhub/swarmhub-manager/references/accounts.md` (`cat` it).
When asked which models the bots or their sub-agents use, first read `~/.hermes/skills/swarmhub/swarmhub-manager/references/models.md` (`cat` it).
When asked about this box's capacity or to set its coding job limit, first read `~/.hermes/skills/swarmhub/swarmhub-manager/references/capacity.md` (`cat` it).

## Heartbeat

A bot's heartbeat is a routine SwarmHub manages: one Hermes cron job per bot that delivers to the bot's chat
(`deliver: bot-chat:<profile>`), named `swarmhub-heartbeat` or an adopted one of the bot's own (such as
`jarvis-hourly-heartbeat-cet`). Hermes has no other kind of heartbeat. Konrad sets it in SwarmHub (Settings → Heartbeat,
`/heartbeat every …`, the chat's Heartbeat bar).
When Konrad asks you to change how often it runs or its hours, edit **that** routine's schedule with the cron tool;
never create a second heartbeat routine. Keep its `deliver: bot-chat:<profile>` as it is. Then say what changed (the old
and the new schedule); SwarmHub reads it back and asks Konrad whether to keep the box's schedule or put its own back.

## Optional connectors

New bots get only the read-only defaults, including aliases in ~/.config/swarmhub/default-connectors.json. Never use --clone-from or copy a manager's config, .env, auth files or workspace into a new bot. Model/provider authentication must be configured separately when needed; do not copy the manager's .env as a shortcut. Existing bots retain their connectors.

Only after the user explicitly selects a connector and one target bot, run:
```sh
python3 ~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py opt-in hermes <bot> --manager default --connector <connector>
```
For OpenClaw use `opt-in openclaw <bot> --manager <manager-agent-id> --connector <connector>` with the same helper. For an inherited connector, add `--source /path/to/its/source-config.json` and select just that entry. This copies just that connector, including its own credentials, to that bot. It never overwrites a connector or broadens an aliased default. Include the returned connectors JSON in the SwarmHub block. Never print the source config, .env, credentials or raw errors.

Read-only inventory (no tool discovery or agent calls): `python3 ~/.hermes/skills/swarmhub/swarmhub-manager/scripts/default-connectors.py audit hermes` (or `audit openclaw`). It lists bot, connector, source config and whether the original source is known; it never removes anything.
