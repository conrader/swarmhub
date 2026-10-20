"""Operator CLI for device approvals: enroll, revoke, list, mode. Box console or SSH only, never a bot turn.

    python3 swarm_devices.py list
    python3 swarm_devices.py enroll <key-id> <ed25519-public-hex> --profile owner [--profile ...] [--label TEXT]
    python3 swarm_devices.py revoke <key-id>
    python3 swarm_devices.py mode required|legacy

Changes refuse to run inside a Hermes gateway (HERMES_* environment or a Hermes ancestor process) and
need a code typed on the controlling terminal (/dev/tty), so a model turn cannot enroll, revoke or
switch modes through this tool. swarmctl exposes none of this. Profiles share one Unix account, so
this is a guard plus a local audit trail, not a boundary against a hostile shell (see SKILL.md).
Key IDs and public keys are never reused; rotation = enroll a new ID, then revoke the old one.
`mode legacy` is the explicit local recovery from device-required; nothing else re-enables v1.
"""
import argparse
import json
import os
import re
import secrets
import subprocess
import sys

sys.dont_write_bytecode = True
import swarm_device_state as ds  # noqa: E402
from swarm_store import database, invoking_profile, profile_exists  # noqa: E402

TTY = "/dev/tty"
HERMES = re.compile(r"hermes(?:[-_][A-Za-z0-9]+)*(?:\.[A-Za-z0-9_]+)*\Z")


class OperatorOnly(PermissionError):
    pass


def ancestors():
    """Command lines of every ancestor process. Unreadable ancestry fails closed."""
    lines, pid = [], os.getppid()
    for _ in range(64):
        if pid <= 1:
            return lines
        result = subprocess.run(["ps", "-o", "ppid=", "-o", "args=", "-p", str(pid)],
                                capture_output=True, text=True)
        fields = result.stdout.strip().split(None, 1)
        if result.returncode or not fields or not fields[0].isdigit():
            raise OperatorOnly("cannot read the process ancestry; run from the box console or an SSH session")
        lines.append(fields[1] if len(fields) > 1 else "")
        pid = int(fields[0])
    raise OperatorOnly("process ancestry too deep")


def hermes_process(command):
    return any(HERMES.match(part) for token in command.split() for part in token.split("/"))


def refuse_model_context(environ=None, ancestry=None):
    env = os.environ if environ is None else environ
    if any(name.startswith("HERMES_") for name in env) or invoking_profile(env):
        raise OperatorOnly("device changes are operator-only: run without HERMES_* set, from the box console or SSH")
    if any(hermes_process(line) for line in (ancestry or ancestors)()):
        raise OperatorOnly("device changes are operator-only: refusing inside a Hermes process tree")


def confirm(summary):
    """Show the change and a fresh code on the controlling terminal; the operator types the code back."""
    code = secrets.token_hex(3)
    try:
        fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY)
    except OSError as error:
        raise OperatorOnly("needs an interactive terminal (box console or SSH session)") from error
    try:
        if not os.isatty(fd):
            raise OperatorOnly("needs an interactive terminal (box console or SSH session)")
        os.write(fd, (summary + "\nType " + code + " to confirm: ").encode())
        answer = b""
        while not answer.endswith(b"\n") and len(answer) < 64:
            chunk = os.read(fd, 64)
            if not chunk:
                break
            answer += chunk
    finally:
        os.close(fd)
    if answer.decode(errors="replace").strip() != code:
        raise OperatorOnly("not confirmed; nothing changed")


def valid_state(db):
    try:
        ds.device_required(db)
        return ds.devices(db)
    except (ds.Refusal, *ds.ERRORS) as error:
        raise ValueError("local device state is invalid; inspect control.sqlite before changing it") from error


def enroll(key_id, public, profiles, label=""):
    refuse_model_context()
    if not ds.matches(key_id, ds.KEY_ID):
        raise ValueError("key ID must match [A-Za-z0-9._-]{1,64}")
    if not ds.matches(public, ds.HEX32) or not ds.prime_point(bytes.fromhex(public)):
        raise ValueError("public key must be a valid Ed25519 point, 64 lowercase hex")
    if (not isinstance(profiles, list) or not profiles or len(set(profiles)) != len(profiles)
            or not all(ds.matches(p, ds.NAME) and profile_exists(p) for p in profiles)):
        raise ValueError("profiles must be distinct existing profiles matching [A-Za-z0-9_-]{1,64}")
    if not isinstance(label, str) or len(label) > 64 or not label.isprintable():
        raise ValueError("label must be at most 64 printable characters")
    now = ds.box_now()
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        known = valid_state(db)
        if key_id in known:
            raise ValueError("key ID was already used on this box; IDs are never reused")
        if any(device["public"] == public for device in known.values()):
            raise ValueError("public key was already enrolled on this box; keys are never reused")
        db.execute("INSERT INTO approval_devices VALUES(?,?,?,0,?,?)",
                   (key_id, public, ds.jcs.canonical(sorted(profiles)).decode(), now, label))
        db.execute("INSERT OR IGNORE INTO approval_mode VALUES(1,0,?)", (now,))
    return listing()


def revoke(key_id):
    refuse_model_context()
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        if key_id not in valid_state(db):
            raise ValueError("unknown key ID")
        # Checked at every consume: outstanding challenges for this key reject from now on.
        db.execute("UPDATE approval_devices SET revoked=1 WHERE key_id=?", (key_id,))
    return listing()


def set_mode(mode):
    refuse_model_context()
    if mode not in ("required", "legacy"):
        raise ValueError("mode must be required or legacy")
    now = ds.box_now()
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        known = valid_state(db)
        if mode == "required" and not any(not d["revoked"] for d in known.values()):
            raise ValueError("enroll an active device before requiring device approvals")
        db.execute("INSERT OR REPLACE INTO approval_mode VALUES(1,?,?)", (int(mode == "required"), now))
    return listing()


def listing():
    with database() as db:
        try:
            required = ds.device_required(db)
            known = ds.devices(db)
        except (ds.Refusal, *ds.ERRORS):
            return {"state": "invalid", "note": "v1 and v2 approvals are refused until this is repaired"}
        rows = db.execute("SELECT key_id,enrolled FROM approval_devices").fetchall()
        enrolled = {row["key_id"]: row["enrolled"] for row in rows}
        return {"mode": "required" if required else "legacy",
                "devices": [{"key_id": k, "public": d["public"], "profiles": d["profiles"], "label": d["label"],
                             "revoked": d["revoked"], "enrolled": enrolled[k]} for k, d in sorted(known.items())]}


def describe(args):
    if args.command == "enroll":
        return ("Enroll device " + args.key_id + " (" + args.public + ") for profiles " + ", ".join(args.profile)
                + ". It can approve or deny managed operations for those profiles.")
    if args.command == "revoke":
        return "Revoke device " + args.key_id + ". This is permanent; its ID cannot be enrolled again."
    if args.mode == "required":
        return "Require device-signed approvals. Every shared-key (v1) approval on this box will be refused."
    return "Return to legacy mode. Shared-key (v1) approvals from the Mac will be accepted again."


def main(argv=None):
    parser = argparse.ArgumentParser(description="Swarm Hub device approvals (operator only)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    add = commands.add_parser("enroll")
    add.add_argument("key_id")
    add.add_argument("public")
    add.add_argument("--profile", action="append", required=True)
    add.add_argument("--label", default="")
    commands.add_parser("revoke").add_argument("key_id")
    commands.add_parser("mode").add_argument("mode", choices=("required", "legacy"))
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            result = listing()
        else:
            refuse_model_context()
            confirm(describe(args))
            result = (enroll(args.key_id, args.public, args.profile, args.label) if args.command == "enroll"
                      else revoke(args.key_id) if args.command == "revoke" else set_mode(args.mode))
    except (OperatorOnly, ValueError) as error:
        print("swarm_devices: " + str(error), file=sys.stderr)
        return 77 if isinstance(error, OperatorOnly) else 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
