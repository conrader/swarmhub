"""Private, captured RPC for the operator tools; never run this on a live box for tests."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import sqlite3
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}\Z")


def name(value):
    if not NAME.fullmatch(value):
        raise ValueError("expected a short name")
    return value


def public_base(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or not re.fullmatch(r"[A-Za-z0-9_.:-]+", parsed.hostname)
            or re.search(r"\s", value) or parsed.username or parsed.password
            or parsed.query or parsed.fragment or not re.fullmatch(r"/[A-Za-z0-9_./-]*|", parsed.path)):
        raise ValueError("base URL must be HTTPS, without credentials, query or fragment")
    parsed.port  # Validate the port too.
    return value.rstrip("/")


class Box:
    """Local box or SSH alias. Secret RPC output is always captured, never forwarded."""
    def __init__(self, account, host=None, checkout=None):
        self.account = name(account)
        self.host = host
        self.checkout = checkout or str(ROOT)
        if host and (host.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_.@-]+", host)):
            raise ValueError("invalid SSH host alias")
        if not Path(self.checkout).is_absolute():
            raise ValueError("box checkout must be an absolute path")

    def run(self, argv, data=None):
        if self.host:
            argv = ["ssh", "-T", "-oBatchMode=yes", "--", self.host, shlex.join(argv)]
        result = subprocess.run(argv, input=data, capture_output=True, timeout=40)
        if result.returncode:
            raise ValueError("box command failed (output withheld; check account/path/permissions)")
        return result.stdout

    def rpc(self, action, **fields):
        argv = ["python3", "-B", str(Path(self.checkout) / "ops/webhook_ops.py"), "--rpc"]
        if self.host or pwd.getpwuid(os.getuid()).pw_name != self.account:
            argv = ["sudo", "-n", "-H", "-u", self.account, "--", *argv]
        return json.loads(self.run(argv, json.dumps({"action": action, **fields}).encode()))

    def system(self, *argv):
        return self.run(["sudo", "-n", "--", *argv]).decode()

    def read(self, path):
        return self.system("cat", "--", str(path))


def account_rpc(request):
    """Runs as the selected account; imports only our skill code, with bytecode disabled."""
    sys.path.insert(0, str(ROOT / "Resources/Skills/swarmhub-messages/scripts"))
    import swarm_webhook as webhook

    action = request["action"]
    profile = name(request["profile"])
    if action == "receipts":
        # Do not call swarm_store.database(): V5 is strictly read-only.
        path = Path.home() / ".hermes/swarmhub/control.sqlite"
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
            answer = []
            for ident in request["deliveries"]:
                row = db.execute("SELECT d.status,r.status FROM deliveries d LEFT JOIN receipts r "
                                 "ON r.id=d.id AND r.target=d.target "
                                 "WHERE d.id=? AND d.target=?", (ident, profile)).fetchone()
                answer.append(list(row) if row else None)
            return answer
    routine = name(request["routine"])
    if action == "register":
        record = webhook.register(profile, routine)
        key = Path(record["key_file"]).read_text().strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{20,200}", key):
            raise ValueError("routine has a hashed or unsupported key; use a new routine")
        return {"slug": record["url"].rsplit("/", 1)[1], "key": key}
    if action == "delete":
        if not routine.startswith("canary-"):
            raise ValueError("only canaries may be removed by the probe")
        return webhook.delete(profile, routine)
    raise ValueError("unsupported operator action")


def box_arguments(parser):
    parser.add_argument("profile", type=name)
    parser.add_argument("--account", help="profile's Unix account (default: hb-<profile>)")
    parser.add_argument("--box", help="SSH alias; omit when running on the box")
    parser.add_argument("--box-checkout", help="absolute checkout path on the box")


def box_from(args):
    return Box(args.account or "hb-" + args.profile, args.box, args.box_checkout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", action="store_true", required=True)
    parser.parse_args()
    try:
        if sys.stdout.isatty():
            raise ValueError("private RPC output must be captured")
        print(json.dumps(account_rpc(json.load(sys.stdin))))
    except Exception:
        # Errors can contain keys, paths or captured output. Do not echo them.
        print("operator RPC failed", file=sys.stderr)
        sys.exit(1)
