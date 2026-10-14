#!/usr/bin/env python3
"""botctl: Jarvis's bot-manager helper on a Hermes box (P22).

Run as the `hermes` user with `python3 -B` (stdlib only; never imports Hermes core, whose tree is
hash-pinned). Commands: list, show, create, set-soul, describe, avatar, retire, reissue-key.
Keys are generated here and written only to the new bot's .env; they are never printed.
"""
import argparse
import datetime as dt
import difflib
import fcntl
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import NoReturn

HERMES_ROOT = Path(os.environ.get("BOTCTL_HERMES_ROOT", "/home/hermes/.hermes"))
PROFILES = HERMES_ROOT / "profiles"
STATE = HERMES_ROOT / "swarmhub"
REGISTRY = STATE / "bots.json"
PENDING = STATE / "pending"
RETIRED = PROFILES / ".retired"
MANAGER = "grok-jarvis"
PROTECTED = {"default", MANAGER}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,40}$")
SOUL_MAX = 60_000
SKILL_REL = Path("skills/agent-operations/bot-manager")
# SwarmHub's mark vocabulary (Sources/AgentApp/Avatars/AvatarMark.swift): a shape word and a colour word.
SHAPES = ("blob pebble bean egg squircle tablet capsule cylinder hex gem crystal wedge shield dome arch cloud "
          "teardrop leaf square sparkle clover flower heart house star").split()
COLOURS = "black brown red orange yellow green cyan blue violet magenta gray".split()


def die(msg, code=1) -> NoReturn:
    print(f"botctl: {msg}", file=sys.stderr)
    sys.exit(code)


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")


def profile_dir(name):
    return PROFILES / name


def is_live(name):
    d = profile_dir(name)
    return d.is_dir() and ((d / "profile.yaml").exists() or (d / "SOUL.md").exists())


def check_name(name, must_exist=True, allow_protected=False):
    if not NAME_RE.match(name or ""):
        die(f"invalid bot name {name!r}: lowercase letters, digits, '-' or '_', 2-41 chars")
    if not allow_protected and name in PROTECTED:
        die(f"{name} is protected; botctl never changes it")
    if must_exist and not is_live(name):
        die(f"no live bot named {name}")


def write_private(path, text):
    """Atomic write, mode 0600."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


class Registry:
    """bots.json under an exclusive lock: {"version":1,"bots":{name:{...}}}. No keys, ever."""

    def __enter__(self):
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._lock = open(STATE / ".lock", "w")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        try:
            self.data = json.loads(REGISTRY.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self.data = {"version": 1, "manager": MANAGER, "bots": {}}
        return self

    def save(self):
        write_private(REGISTRY, json.dumps(self.data, indent=2, sort_keys=True) + "\n")

    def __exit__(self, *exc):
        fcntl.flock(self._lock, fcntl.LOCK_UN)
        self._lock.close()


def read_description(name):
    p = profile_dir(name) / "profile.yaml"
    try:
        for line in p.read_text(encoding="utf-8").splitlines():
            if line.startswith("description:"):
                raw = line.split(":", 1)[1].strip()
                if raw.startswith('"'):
                    try:
                        return json.loads(raw)
                    except ValueError:
                        pass
                return raw.strip("'\"")
    except OSError:
        pass
    return ""


def write_description(name, description):
    p = profile_dir(name) / "profile.yaml"
    keep = []
    if p.exists():
        keep = [ln for ln in p.read_text(encoding="utf-8").splitlines()
                if not ln.startswith(("description:", "description_auto:"))]
    lines = [f"description: {json.dumps(description, ensure_ascii=False)}", "description_auto: false", *keep]
    write_private(p, "\n".join(lines) + "\n")


def first_line(text):
    for line in text.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:120]
    return ""


def read_soul(name):
    try:
        return (profile_dir(name) / "SOUL.md").read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def load_text(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        die(f"cannot read {path}: {exc.strerror}")
    if not text.strip():
        die("instructions are empty")
    if len(text) > SOUL_MAX:
        die(f"instructions are {len(text)} chars; the limit is {SOUL_MAX}")
    return text if text.endswith("\n") else text + "\n"


def set_avatar(reg, name, shape, colour):
    if shape not in SHAPES:
        die(f"unknown shape {shape!r}; one of: {' '.join(SHAPES)}")
    if colour not in COLOURS:
        die(f"unknown colour {colour!r}; one of: {' '.join(COLOURS)}")
    reg.data.setdefault("avatars", {})[name] = {"shape": shape, "colour": colour, "updated": now()}


def set_key(name):
    """Fresh API_SERVER_KEY in the bot's .env (other lines kept). Never printed."""
    env = profile_dir(name) / ".env"
    lines = []
    if env.exists():
        lines = [ln for ln in env.read_text(encoding="utf-8").splitlines() if not ln.startswith("API_SERVER_KEY=")]
    lines.append(f"API_SERVER_KEY={secrets.token_hex(32)}")
    write_private(env, "\n".join(lines) + "\n")
    PENDING.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_private(PENDING / name, now() + "\n")


# -- commands -----------------------------------------------------------------------------------

def cmd_list(args):
    with Registry() as reg:
        managed = reg.data["bots"]
        avatars = reg.data.get("avatars", {})
    rows = []
    for d in sorted(PROFILES.iterdir()):
        if not d.is_dir() or not NAME_RE.match(d.name) or not is_live(d.name):
            continue
        rows.append({"name": d.name, "description": read_description(d.name),
                     "instructions": first_line(read_soul(d.name)),
                     "managed_by_jarvis": d.name in managed,
                     "paused": (d / "gateway.parked").exists(),
                     "key_waiting_for_swarmhub": (PENDING / d.name).exists(),
                     "avatar": {k: v for k, v in avatars.get(d.name, {}).items() if k != "updated"} or None})
    if args.all:
        for name, meta in sorted(managed.items()):
            if meta.get("retired"):
                rows.append({"name": name, "retired": meta["retired"], "kept_at": meta.get("retired_path", "")})
    print(json.dumps(rows, indent=2, ensure_ascii=False))


def cmd_show(args):
    check_name(args.name, allow_protected=True)
    text = read_soul(args.name)
    print(text if text else f"({args.name} has no SOUL.md)")


def cmd_create(args):
    check_name(args.name, must_exist=False)
    if profile_dir(args.name).exists():
        die(f"{args.name} already exists")
    soul = load_text(args.soul_file)
    if bool(args.shape) != bool(args.colour):
        die("give both --shape and --colour, or neither")
    if args.shape and (args.shape not in SHAPES or args.colour not in COLOURS):
        die(f"avatar must be a shape ({' '.join(SHAPES)}) and a colour ({' '.join(COLOURS)})")
    description = args.description.strip()
    if not description:
        die("a one-sentence description is required")
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERMES_")}
    env.update(HERMES_HOME=str(HERMES_ROOT), PYTHONDONTWRITEBYTECODE="1")
    cmd = ["hermes", "profile", "create", args.name, "--clone-from", args.template,
           "--no-alias", "--description", description]
    res = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=180)
    if res.returncode != 0 or not profile_dir(args.name).is_dir():
        tail = (res.stderr or res.stdout).strip().splitlines()[-3:]
        die("hermes profile create failed: " + " | ".join(tail))
    d = profile_dir(args.name)
    set_key(args.name)                      # the clone carried the template's key; replace it
    shutil.rmtree(d / SKILL_REL, ignore_errors=True)   # only Jarvis manages bots
    for rel in ("memories/MEMORY.md", "memories/USER.md"):
        (d / rel).unlink(missing_ok=True)   # D5: fresh memories
    write_private(d / "SOUL.md", soul)
    write_description(args.name, description)
    with Registry() as reg:
        reg.data["bots"][args.name] = {"description": description, "created": now(), "updated": now(),
                                       "template": args.template, "retired": None}
        if args.shape:
            set_avatar(reg, args.name, args.shape, args.colour)
        reg.save()
    print(f"created {args.name}: own key generated (not shown), instructions {len(soul)} chars, "
          f"memories empty. SwarmHub will offer it under 'New bots from Jarvis'.")


def cmd_set_soul(args):
    check_name(args.name)
    old = read_soul(args.name)
    new = load_text(args.file)
    diff = list(difflib.unified_diff(old.splitlines(), new.splitlines(), f"{args.name} now", f"{args.name} new",
                                     lineterm=""))
    if not diff:
        print("no change")
        return
    print("\n".join(diff))
    if args.dry_run:
        print("\n(dry run: nothing written)")
        return
    d = profile_dir(args.name)
    prev = d / f"SOUL.md.prev-{stamp()}"
    if old:
        write_private(prev, old)
    write_private(d / "SOUL.md", new)
    with Registry() as reg:
        if args.name in reg.data["bots"]:
            reg.data["bots"][args.name]["updated"] = now()
            reg.save()
    print(f"\nwrote {args.name}/SOUL.md" + (f"; previous kept as {prev.name}" if old else ""))


def cmd_describe(args):
    check_name(args.name)
    write_description(args.name, args.description.strip())
    with Registry() as reg:
        if args.name in reg.data["bots"]:
            reg.data["bots"][args.name].update(description=args.description.strip(), updated=now())
            reg.save()
    print(f"{args.name}: description updated")


def cmd_avatar(args):
    check_name(args.name, allow_protected=True)
    if args.name == "default":
        die("default has no SwarmHub avatar")
    with Registry() as reg:
        set_avatar(reg, args.name, args.shape, args.colour)
        reg.save()
    print(f"{args.name}: avatar set to a {args.colour} {args.shape}; SwarmHub shows it on its next refresh")


def cmd_retire(args):
    check_name(args.name)
    d = profile_dir(args.name)
    (d / "gateway.parked").touch()          # Hermes stops serving a parked profile
    time.sleep(3)
    RETIRED.mkdir(mode=0o700, parents=True, exist_ok=True)
    dest = RETIRED / f"{args.name}-{stamp()}"
    shutil.move(str(d), str(dest))
    (PENDING / args.name).unlink(missing_ok=True)
    with Registry() as reg:
        meta = reg.data["bots"].setdefault(args.name, {"description": "", "created": None})
        meta.update(retired=now(), retired_path=str(dest), updated=now())
        reg.save()
    print(f"retired {args.name}: no longer served; everything kept at {dest}")


def cmd_reissue_key(args):
    check_name(args.name)
    with Registry() as reg:
        if args.name not in reg.data["bots"]:
            die(f"{args.name} was not created by Jarvis; its key is managed in SwarmHub settings")
    set_key(args.name)
    print(f"{args.name}: new key generated (not shown); SwarmHub can collect it once")


def main(argv=None):
    if os.geteuid() == 0:
        die("run as the hermes user, not root")
    ap = argparse.ArgumentParser(prog="botctl")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--all", action="store_true"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("show"); p.add_argument("name"); p.set_defaults(fn=cmd_show)
    p = sub.add_parser("create"); p.add_argument("name"); p.add_argument("--description", required=True)
    p.add_argument("--soul-file", required=True); p.add_argument("--template", default=MANAGER)
    p.add_argument("--shape"); p.add_argument("--colour")
    p.set_defaults(fn=cmd_create)
    p = sub.add_parser("set-soul"); p.add_argument("name"); p.add_argument("--file", required=True)
    p.add_argument("--dry-run", action="store_true"); p.set_defaults(fn=cmd_set_soul)
    p = sub.add_parser("describe"); p.add_argument("name"); p.add_argument("--description", required=True)
    p.set_defaults(fn=cmd_describe)
    p = sub.add_parser("avatar"); p.add_argument("name"); p.add_argument("--shape", required=True)
    p.add_argument("--colour", required=True); p.set_defaults(fn=cmd_avatar)
    p = sub.add_parser("retire"); p.add_argument("name"); p.set_defaults(fn=cmd_retire)
    p = sub.add_parser("reissue-key"); p.add_argument("name"); p.set_defaults(fn=cmd_reissue_key)
    args = ap.parse_args(argv)
    if getattr(args, "template", None):
        check_name(args.template, allow_protected=True)
    args.fn(args)


if __name__ == "__main__":
    main()
