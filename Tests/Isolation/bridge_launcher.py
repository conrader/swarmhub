"""fake_sudo's command: ops/isolation/peer_bridge.main with fixture accounts (Tests/Isolation only).

The privilege drop is recorded in <root>/drops.log instead of performed: the sandbox has one uid. drop_privileges
itself is covered by test_peer_bridge_identity.py with a stand-in os module.
"""
import json
import os
import sys
from pathlib import Path

accounts_file, bridge, *argv = sys.argv[1:]
sys.path.insert(0, str(Path(bridge).parent))
import peer_bridge  # noqa: E402

ROOT = Path(bridge).parents[4]  # <root>/usr/local/lib/swarmhub/peer-bridge


class Accounts:
    def __init__(self, data):
        self.data = data

    def account(self, name):
        entry = self.data[name]
        return peer_bridge.Account(name, entry["uid"], entry["gid"], entry["home"])

    def by_uid(self, uid):
        return next((self.account(name) for name, entry in self.data.items() if entry["uid"] == uid), None)

    def by_name(self, name):
        return self.account(name) if name in self.data else None


def drop(account):
    with open(ROOT / "drops.log", "a") as handle:
        handle.write(f"{os.getpid()} {account.name}\n")


with open(accounts_file) as handle:
    accounts = Accounts(json.load(handle))
sys.exit(peer_bridge.main(argv, os.environ, sys.stdin.buffer, sys.stdout, sys.stderr, accounts, drop,
                          registry_path=str(ROOT / "etc/swarmhub/bots.json")))
