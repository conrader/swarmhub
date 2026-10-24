# Per-bot accounts: `hb-move`, `hermes-bot@`, `peer-bridge`

Design: swapdesign2 §2, as amended by swapdesign3 §3 and its addendum (a). Konrad approved the per-bot user and gateway
isolation on 2026-10-24. Everything here is our own code and config. Hermes is not changed.

## Why

Every profile on a box runs as the unix user `hermes` in one multiplexed gateway. Any file or terminal tool can
therefore read every profile's `.env` and every jobroute key. Removing tools box-wide would break the skill scripts, so
the boundary has to be a uid. Each migrated bot gets:

- user `hb-<slug>` with a home at mode 0700, its profile in `~hb-<slug>/.hermes/profiles/<profile>/` and an empty
  `~/.ssh` (0700) for the jobroute key that PR 7 adds;
- a stock gateway `hermes-bot@<slug>` (`ops/isolation/hermes-bot@.service`) on a loopback port;
- its own webhook receiver and control port;
- an nginx route `/p/<profile>/` to its port. The app address and the profile's API key stay the same.

The root-owned registry `/etc/swarmhub/bots.json` (0644, no secrets, `ops/isolation/swarmhub_registry.py`) maps each
profile to its user, its uid and its three ports. Only `hb-move` writes it.

## Messages between accounts

`bot-msg` reads the registry. A target in another account is reached through the bridge, and the sender never reads
that bot's key:

```
sudo -n /usr/local/lib/swarmhub/peer-bridge <held|durable|stream> <to> --from-profile <me> [--max-time <s>]
```

- **stdin, never argv.** The text arrives on stdin as `<bytes>\n<text>`, because sudo logs argv.
- **Who is sending.** The bridge takes the sender's account from `SUDO_UID`, never from `SUDO_USER`.
  - A registered account may send only as its own slug. bot-msg replaces a forged `--from` with that slug, and a
    direct call with any other slug exits 77.
  - `hermes` may send as any of its own profiles that is not a registry slug. Those messages are recorded
    `tier=shared` and prefixed `[Message from <p> via SwarmHub (shared)]`.
  - Any other uid exits 77.
- **What runs where.** As root, the bridge only reads the registry and checks that a shared sender's profile folder
  exists. It then drops to the recipient's account.
  - `held` and `durable` run the recipient's own `peer-runtime.py hold-stdin` and `swarmctl enqueue-stdin`.
  - `stream` creates `swarmhub-from-<sender>` and builds the input itself, with the recipient's key passed to curl
    on stdin only.
- **The reply.** It streams back on stdout, and the bridge's last stderr line is `bridge: http=<code> rc=<rc>`.
  - The sender keeps the bridge's stdin open through a holder process that the sender owns. Cancelling a task ends
    the holder, and so does a dying sender. The pipe closes and the bridge stops. No signal crosses a uid.
  - A late reply is delivered by the sender's own bot-msg, in the sender's account, with the sender's key.
- **Logs.** Each delivery is logged in the recipient's `~/.hermes/swarmhub/peer-bridge.log`: time, verb, sender, tier,
  recipient and result. The log never contains the text or a key.

sudoers (`ops/isolation/sudoers-swarmhub-peer-bridge`) lets group `swarmhub-peer` run only that one root-owned program,
with `env_reset` and `!use_pty`.

## Move one bot (as root, in a quiet window)

1. Add the snippet include to the Hermes site's server block, before its generic `/p/` location:
   `include /etc/nginx/snippets/swarmhub-bots.conf;`. Then run `nginx -t`. hb-move refuses to start without the
   include.
2. Run a dry run first, then the real move:
   `sudo ops/hb-move grok-<slug> --gateway-port 8651 --receiver-port 8751 --control-port 8761 --dry-run`
3. The move stops at the first red step and journals what it did in `/var/lib/swarmhub/hb-move/<profile>.json`. It
   prints no key. The checks it makes are: `/health` on the gateway port; the receiver's health on its port (this
   needs `receiver install --port` from swarmhub PR #26, and an older skill silently uses 8745); `nginx -t`; and
   `visudo -cf`.
4. Then start the account's control server on its control port (`swarmctl control serve <origin> <port>` as
   `hb-<slug>`). hb-move does not start it.
5. Run `ops/wake-enroll` and `ops/webhook-probe` (PR #27) for the bot. Probe f must now give 400 at 8745.

**Rollback:** `sudo ops/hb-move --undo grok-<slug>`. It does the following:

- stops and disables the unit and removes its drop-in;
- uninstalls the account's receiver;
- copies the bot's current profile back to `~hermes` (owner `hermes`) and keeps the dedicated copy as `<profile>.<n>.dedicated`;
- removes the registry entry and re-renders nginx;
- removes sudoers when no bot is left.

Three things stay manual: the account itself (`userdel -r hb-<slug>` once the shared profile answers again),
`wake.env.<stamp>`, and the 8745 routine.

## Tests

Run them only in the sandbox (`sim/ISOLATION.md`):

```sh
sudo -u sbtest -- unshare -r -p -f --mount-proc python3 -B -m unittest discover -s Tests/Isolation -p 'test_*.py'
```

The sandbox maps a single uid. Accounts are therefore fixtures: separate homes, keys and stub gateways, and a test sudo
stand-in (`Tests/Isolation/fake-sudo`) that resets the environment, sets `SUDO_UID` and runs the bridge in its own
session. The shipped bot-msg, peer-runtime, swarmctl and bridge run unchanged.

The privilege drop is recorded rather than performed. `drop_privileges` has its own unit test with a stand-in `os`.
hb-move runs against a throwaway root with logging stand-ins for useradd, systemctl, nginx and the other commands. The
sudoers text is checked by the real `visudo`.

## Not verified

- **Real uids.** Nothing here ran under real separate uids, real sudo, systemd or nginx. On the box, the pilot must show:
  - `hb-b` cannot read `~hb-a`;
  - the real `sudo -n` passes no environment;
  - `!use_pty` holds;
  - the late reply still arrives from a tty (test L9 covers the shell part).
- **OAuth logins.** Model provider logins live in the shared Hermes root and are not copied. The pilot must show the
  moved bot still answers, or use the narrow credential transfer or a fresh login.
- **The shared gateway** keeps a moved profile loaded until it restarts. hb-move does not restart it.
- **The nginx `/p/` block** copies typical SSE proxy settings. Compare it with the site's existing `/p/` location
  (`nginx -T`) before the pilot.
