# Box side of P22: Jarvis manages bots

Files installed on a Hermes box (Konrad's: 195.201.33.222). Nothing here imports Hermes core.

| File | Installed at | What it does |
|---|---|---|
| `SKILL.md`, `botctl.py` | `~hermes/.hermes/profiles/grok-jarvis/skills/agent-operations/bot-manager/` | Jarvis's skill and helper: create / list / show / set-soul / describe / avatar / retire / reissue-key |
| `server.py` | `/opt/swarmhub-bots/server.py` (root-owned, read-only) | the route SwarmHub calls, as user `hermes` on 127.0.0.1:8644 |
| `swarmhub-bots.service` | `/etc/systemd/system/` | runs `server.py` with `python3 -B` |
| `nginx-swarmhub.conf` | inside the box's published server block | `/swarmhub/` → 127.0.0.1:8644; `/p/grok-` widened to `/p/` so new bots answer |

State: `~hermes/.hermes/swarmhub/bots.json` (registry, no keys) and `swarmhub/pending/<bot>`
(empty marker: a key SwarmHub has not collected yet). Retired bots: `profiles/.retired/<bot>-<ts>`.

## Route (all but `/health` need Jarvis's API key as `Authorization: Bearer`)

| Call | Returns |
|---|---|
| `GET /swarmhub/v1/health` | `{"ok": true}` |
| `GET /swarmhub/v1/bots` | `{"manager", "bots": [{name, description, managed_by_jarvis, paused, key_waiting, has_key, instructions_updated, avatar}], "retired": [{name, retired}]}` |
| `GET /swarmhub/v1/bots/<name>/instructions` | `{"name", "text", "updated"}` (the bot's SOUL.md) |
| `POST /swarmhub/v1/bots/<name>/claim-key` | `{"name", "key"}` once while `key_waiting`; then 404 |

Bots answer at `/p/<name>/v1/...` with their own key, like the grok bots.
