"""hb-move: move one Hermes profile into its own unix account and stock gateway (swapdesign2 §2, PR 5).

    sudo ops/hb-move <profile> --gateway-port N --receiver-port N --control-port N --shared-unit <unit|none>
                     [--user hb-<slug>] [--dry-run]
    sudo ops/hb-move --undo <profile> [--dry-run]
    sudo ops/hb-move --render-nginx

Run as root on the box, in a quiet window, one bot at a time (docs/bot-isolation.md). It never changes Hermes code and
never prints a key. Every step is journaled in /var/lib/swarmhub/hb-move/<profile>.json, so --undo reverses exactly
what was done; a red check stops the move where it is, and --undo takes it back. --root <dir> prefixes every path
(tests only).

Move: group swarmhub-peer (hermes and the bot account in it) -> account hb-<slug> (home 0700, ~/.ssh 0700) -> copy of
the profile into ~hb-<slug>/.hermes/profiles/<profile>/ and the shared original renamed to a numbered backup in
<shared home's parent>/.swarmhub-hb-move/ (root 0700), with the shared gateway (--shared-unit) stopped in between and
always started again -> registry entry -> peer-bridge + sudoers (visudo -cf) -> hermes-bot@<slug> with its
port drop-in, started and answering /health -> the account's own webhook receiver on its port (needs the receiver's
`--port`, swarmhub PR #26; checked by probing that port) -> the nginx snippet (nginx -t, reload).
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / "isolation")]
import hb_render  # noqa: E402
import swarmhub_registry as registry  # noqa: E402

LIB = "/usr/local/lib/swarmhub"
BRIDGE_FILES = (("peer-bridge", 0o755), ("peer_bridge.py", 0o644), ("swarmhub_registry.py", 0o644))
SUDOERS = "/etc/sudoers.d/swarmhub-peer-bridge"
UNIT = "/etc/systemd/system/hermes-bot@.service"
JOURNAL = "/var/lib/swarmhub/hb-move"
GROUP = "swarmhub-peer"
SKILL = "skills/swarmhub/swarmhub-messages/scripts"
HEALTH_TRIES = 30


class Failed(Exception):
    pass


class Account:
    def __init__(self, line):
        fields = line.strip().split(":")
        self.name, self.uid, self.gid, self.home = fields[0], int(fields[2]), int(fields[3]), fields[5]


class Box:
    """Paths under --root, commands logged before they run, nothing changed in --dry-run (queries still run)."""

    def __init__(self, root="/", dry_run=False, out=print):
        self.root, self.dry, self.out = Path(root), dry_run, out

    def path(self, absolute):
        return self.root / str(absolute).lstrip("/")

    def run(self, argv):
        self.out("+ " + " ".join(str(a) for a in argv))
        if self.dry:
            return ""
        result = subprocess.run([str(a) for a in argv], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if result.returncode:
            raise Failed(f"{argv[0]} exited {result.returncode}: {result.stderr.strip()[:300]}")
        return result.stdout

    def query(self, argv):
        result = subprocess.run(argv, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return result.returncode, result.stdout

    def account(self, name):
        rc, out = self.query(["getent", "passwd", name])
        return Account(out) if rc == 0 and out.count(":") >= 6 else None

    def write(self, absolute, text, mode):
        target = self.path(absolute)
        self.out(f"+ write {absolute} ({mode:o})")
        if self.dry:
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_name(f".{target.name}.hb-move.tmp")
        temp.write_text(text, encoding="utf-8")
        temp.chmod(mode)
        os.replace(temp, target)

    def answers(self, port, path, tries):
        for attempt in range(tries):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
                    if response.status == 200:
                        return True
            except OSError:
                pass
            if attempt + 1 < tries:
                time.sleep(1)
        return False


class Journal:
    def __init__(self, box, profile):
        self.box, self.path = box, box.path(JOURNAL) / f"{profile}.json"
        self.data = json.loads(self.path.read_text()) if self.path.exists() else None

    def start(self, **fields):
        self.data = dict(fields, steps=[], started=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        self.save()

    def done(self, step, **fields):
        self.data["steps"].append(step)
        self.data.update(fields)
        self.save()

    def save(self):
        if self.box.dry:
            return
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps(self.data, indent=2, sort_keys=True) + "\n")
        temp.chmod(0o600)
        os.replace(temp, self.path)


def load_registry(box):
    path = box.path(registry.PATH)
    return registry.load(path, trusted=False) if path.exists() else registry.empty()


def port_free(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def backups(shared):
    """Root-only folder for retired profiles, next to the shared home, so retiring is an atomic rename."""
    return Path(shared.home).parent / ".swarmhub-hb-move"


def next_backup(box, folder, profile, suffix=""):
    """The first free <folder>/<profile>.<n><suffix>, as a path on the box (not under --root)."""
    n = 1
    while box.path(folder / f"{profile}.{n}{suffix}").exists():
        n += 1
    return folder / f"{profile}.{n}{suffix}"


def set_aside(box, path, backup):
    box.out(f"+ mv {path} {backup}")
    if not box.dry:
        box.path(backup).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.move(str(path), str(box.path(backup)))


def render_nginx(box):
    """The snippet from the registry; on a failing `nginx -t` the previous snippet comes back and the move stops."""
    target = box.path(hb_render.SNIPPET)
    previous = target.read_text() if target.exists() else None
    box.write(hb_render.SNIPPET, hb_render.nginx(load_registry(box)), 0o644)
    try:
        box.run(["nginx", "-t"])
    except Failed:
        if previous is None:
            target.unlink(missing_ok=True)
        else:
            box.write(hb_render.SNIPPET, previous, 0o644)
        raise
    box.run(["systemctl", "reload", "nginx"])


def install_bridge(box):
    lib = box.path(LIB)
    box.out(f"+ install {LIB}/{{peer-bridge,peer_bridge.py,swarmhub_registry.py}} (root, 0755)")
    if not box.dry:
        lib.mkdir(mode=0o755, parents=True, exist_ok=True)
        lib.chmod(0o755)
        for name, mode in BRIDGE_FILES:
            temp = lib / f".{name}.tmp"
            shutil.copyfile(HERE / "isolation" / name, temp)
            temp.chmod(mode)
            os.replace(temp, lib / name)
    box.run(["chown", "-R", "root:root", lib])
    temp = SUDOERS.replace("swarmhub-peer-bridge", ".swarmhub-peer-bridge.tmp")  # sudo skips dotted names
    box.write(temp, (HERE / "isolation/sudoers-swarmhub-peer-bridge").read_text(), 0o440)
    try:
        box.run(["visudo", "-cf", box.path(temp)])
    except Failed:
        box.path(temp).unlink(missing_ok=True)
        raise
    box.out(f"+ mv {temp} {SUDOERS}")
    if not box.dry:
        os.replace(box.path(temp), box.path(SUDOERS))


def preflight(box, profile, user, ports, shared_user):
    if not registry.NAME.fullmatch(profile) or profile == "default":
        raise Failed(f"{profile!r} is not a named profile")
    if not registry.USER.fullmatch(user) or not user.startswith("hb-") or len(user) < 4:
        raise Failed("--user must be hb-<slug> (lower case, at most 32 characters)")
    current = load_registry(box)
    if profile in current["bots"] or Journal(box, profile).data is not None:
        raise Failed(f"{profile} is already moved or half-moved (registry or journal); use --undo first")
    shared = box.account(shared_user)
    if shared is None:
        raise Failed(f"no shared account {shared_user}")
    source = box.path(shared.home) / ".hermes/profiles" / profile
    if source.is_symlink() or not source.is_dir():
        raise Failed(f"no profile {profile} in {shared.home}/.hermes/profiles")
    if not (source / SKILL / "swarmctl").is_file():
        raise Failed(f"{profile} has no swarmhub-messages skill; install it first (its receiver and bot-msg need it)")
    candidate = json.loads(json.dumps(current))
    candidate["bots"][profile] = dict(user=user, uid=2 ** 31 - 1, **ports)
    try:
        registry.validate(candidate)
    except registry.RegistryError as exc:
        raise Failed(str(exc)) from None
    busy = [port for port in ports.values() if not port_free(port)]
    if busy:
        raise Failed(f"ports already in use on 127.0.0.1: {busy}")
    rc, config = box.query(["nginx", "-T"])
    if rc != 0 or hb_render.INCLUDE not in config:
        raise Failed(f"nginx does not include the bot snippet yet: add `{hb_render.INCLUDE}` to the Hermes server "
                     "block first (before its /p/ location), then `nginx -t`")
    return shared, source


def move(box, profile, user, ports, shared_unit, shared_user="hermes"):
    shared, source = preflight(box, profile, user, ports, shared_user)
    instance = user[3:]
    journal = Journal(box, profile)
    journal.start(profile=profile, user=user, instance=instance, ports=ports, shared_user=shared_user,
                  shared_unit=shared_unit)
    rc, _ = box.query(["getent", "group", GROUP])
    if rc != 0:
        box.run(["groupadd", "--system", GROUP])
        journal.done("group-created")
    box.run(["usermod", "-aG", GROUP, shared_user])
    account = box.account(user)
    if account is None:
        box.run(["useradd", "--system", "--user-group", "--create-home", "--home-dir", f"/home/{user}",
                 "--shell", "/usr/sbin/nologin", user])
        journal.done("user-created")
        account = box.account(user)
    if account is None:  # dry run: nothing was created
        account = Account(f"{user}:x:0:0::/home/{user}:/usr/sbin/nologin")
    box.run(["usermod", "-aG", GROUP, user])
    home = box.path(account.home)
    target = home / ".hermes/profiles" / profile
    if target.exists():
        raise Failed(f"{account.home}/.hermes/profiles/{profile} already exists")
    if not box.dry:
        for folder in (home, home / ".hermes", home / ".hermes/profiles", home / ".ssh"):
            folder.mkdir(mode=0o700, parents=True, exist_ok=True)
            folder.chmod(0o700)
    # The shared gateway writes into the profile (sessions, memory) and would keep writing into the retired copy, so
    # it is stopped from the copy until the original is retired, and always started again. Intent is journaled before
    # each step, so --undo knows a half-done copy or retire.
    stopped = False
    try:
        if shared_unit != "none":
            box.run(["systemctl", "stop", shared_unit])
            stopped = True
            journal.done("shared-stopped")
        journal.done("copying", target=str(target))
        box.run(["cp", "-a", source, target])
        if not box.dry and sorted(p.relative_to(source) for p in source.rglob("*")) != \
                sorted(p.relative_to(target) for p in target.rglob("*")):
            raise Failed("the copy does not match the original; nothing retired")
        journal.done("copied")
        backup = next_backup(box, backups(shared), profile)
        journal.done("retiring", backup=str(backup))
        box.out(f"+ mv {source} {backup}")
        if not box.dry:
            box.path(backups(shared)).mkdir(mode=0o700, parents=True, exist_ok=True)
            box.path(backups(shared)).chmod(0o700)
            os.rename(source, box.path(backup))  # atomic: the backups sit next to the shared home, same filesystem
        journal.done("retired")
    finally:
        if stopped:
            box.run(["systemctl", "start", shared_unit])
            journal.done("shared-started")
    bot = dict(user=user, uid=account.uid, **ports)
    if not (home / ".hermes/.env").exists():
        box.write(f"{account.home}/.hermes/.env", hb_render.default_env(bot, secrets.token_hex(24)), 0o600)
    box.run(["chown", "-R", f"{user}:{user}", home])
    journal.done("owned")
    box.out(f"+ registry: {profile} -> {user} (uid {account.uid}), ports {ports}")
    if not box.dry:
        with registry.locked(box.path(registry.PATH)) as current:
            current["bots"][profile] = bot
            registry.save(box.path(registry.PATH), current)
    journal.done("registered")
    install_bridge(box)
    journal.done("bridge")
    unit = f"hermes-bot@{instance}.service"
    box.write(UNIT, (HERE / "isolation/hermes-bot@.service").read_text(), 0o644)
    box.write(f"/etc/systemd/system/{unit}.d/10-ports.conf", hb_render.dropin(bot), 0o644)
    box.run(["systemctl", "daemon-reload"])
    box.run(["systemctl", "enable", "--now", unit])
    journal.done("unit")
    if not box.dry and not box.answers(ports["gateway_port"], "/health", HEALTH_TRIES):
        raise Failed(f"{unit} does not answer on 127.0.0.1:{ports['gateway_port']}/health; see journalctl -u "
                     f"{unit}; the move stopped here and --undo {profile} takes it back")
    swarmctl = f"{account.home}/.hermes/profiles/{profile}/{SKILL}/swarmctl"
    box.run(["runuser", "-u", user, "--", "env", f"HOME={account.home}", "PATH=/usr/bin:/bin",
             "PYTHONDONTWRITEBYTECODE=1", "/usr/bin/python3", "-B", swarmctl, "webhook", "receiver", "install",
             "--port", ports["receiver_port"]])
    journal.done("receiver")
    if not box.dry and not box.answers(ports["receiver_port"], "/swarmhub/webhook/health", 10):
        raise Failed(f"no webhook receiver on 127.0.0.1:{ports['receiver_port']}: the skill in {profile} needs "
                     "`receiver install --port` (swarmhub PR #26); the move stopped here")
    render_nginx(box)
    journal.done("nginx")
    journal.done("verified")
    box.out(f"moved {profile} into {user}; backup {backup}. Next: wake-enroll and webhook-probe (ops/README.md), "
            f"and start its control server in that account on port {ports['control_port']} (docs/bot-isolation.md).")


def undo(box, profile):
    journal = Journal(box, profile)
    if journal.data is None:
        raise Failed(f"no journal for {profile} in {JOURNAL}; nothing to undo")
    data, steps = journal.data, journal.data["steps"]
    user, unit = data["user"], f"hermes-bot@{data['instance']}.service"
    shared, account = box.account(data["shared_user"]), box.account(user)
    if shared is None:
        raise Failed(f"no shared account {data['shared_user']}; the original is in {data.get('backup', '(not retired)')}")
    shared_unit = data.get("shared_unit", "none")
    restore = box.path(shared.home) / ".hermes/profiles" / profile
    in_place = restore.exists() or restore.is_symlink()
    if "retired" in steps and in_place:
        raise Failed(f"{restore} exists again; refusing to overwrite it")
    if "unit" in steps:
        box.run(["systemctl", "disable", "--now", unit])
        box.out(f"+ rm -r /etc/systemd/system/{unit}.d")
        if not box.dry:
            shutil.rmtree(box.path(f"/etc/systemd/system/{unit}.d"), ignore_errors=True)
        box.run(["systemctl", "daemon-reload"])
    if "receiver" in steps and account is not None:
        swarmctl = f"{account.home}/.hermes/profiles/{profile}/{SKILL}/swarmctl"
        box.run(["runuser", "-u", user, "--", "env", f"HOME={account.home}", "PATH=/usr/bin:/bin",
                 "PYTHONDONTWRITEBYTECODE=1", "/usr/bin/python3", "-B", swarmctl, "webhook", "receiver", "uninstall"])
    moved = box.path(account.home) / ".hermes/profiles" / profile if account else None
    if "retiring" in steps and not in_place:
        # The original left the shared account. The bot's state since the move comes back with it (else the retired
        # original does); the dedicated copy is kept as another numbered backup, never deleted.
        source = moved if moved is not None and moved.is_dir() and "copied" in steps else box.path(data["backup"])
        # Copied beside the target and renamed into place, so a crashed undo never leaves a truncated profile that a
        # second undo would take for the original. A leftover temp copy is only ever a copy of `source`.
        temp = restore.with_name(f".{profile}.hb-undo")
        if not box.dry and temp.exists():
            shutil.rmtree(temp)
        box.run(["cp", "-a", source, temp])
        box.run(["chown", "-R", f"{shared.name}:{shared.name}", temp])
        box.out(f"+ mv {temp} {restore}")
        if not box.dry:
            os.rename(temp, restore)
        if source == moved:
            set_aside(box, moved, next_backup(box, backups(shared), profile, ".dedicated"))
    elif moved is not None and moved.exists() and "copying" in steps:
        # Never retired: the original is still in place, and the (maybe partial) copy is only set aside.
        set_aside(box, moved, next_backup(box, backups(shared), profile, ".partial"))
    if shared_unit != "none" and ("shared-stopped" in steps or "retiring" in steps):
        # Also after a hard crash that skipped the move's own restart; serves the restored profile again.
        box.run(["systemctl", "restart", shared_unit])
    path = box.path(registry.PATH)
    if path.exists() and profile in load_registry(box)["bots"]:
        box.out(f"+ registry: remove {profile}")
        if not box.dry:
            with registry.locked(path) as current:
                del current["bots"][profile]
                registry.save(path, current)
    if "nginx" in steps or "registered" in steps:
        render_nginx(box)
    if not set(load_registry(box)["bots"]) - {profile}:
        box.out(f"+ rm {SUDOERS} (no bot account left)")
        if not box.dry:
            box.path(SUDOERS).unlink(missing_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    box.out(f"+ mv {journal.path} {journal.path}.undone.{stamp}")
    if not box.dry:
        os.replace(journal.path, journal.path.with_name(f"{profile}.json.undone.{stamp}"))
    box.out(f"undone {profile}. The account {user} stays (remove it with `userdel -r {user}` once the shared profile "
            "answers again); restore wake.env.<stamp> and re-register the 8745 routine (ops/README.md).")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="hb-move", description=__doc__.split("\n\n")[0])
    parser.add_argument("profile", nargs="?")
    parser.add_argument("--undo", action="store_true")
    parser.add_argument("--render-nginx", action="store_true")
    parser.add_argument("--user")
    for name in registry.PORTS:
        parser.add_argument("--" + name.replace("_", "-"), type=int)
    parser.add_argument("--shared-user", default="hermes")
    parser.add_argument("--shared-unit", help="the shared gateway's systemd unit, stopped during the copy (or none)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--root", default="/", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.root == "/" and os.geteuid() != 0:
        parser.error("run it as root on the box")
    box = Box(args.root, args.dry_run)
    try:
        if args.render_nginx:
            render_nginx(box)
        elif args.undo and args.profile:
            undo(box, args.profile)
        elif args.profile and all(getattr(args, name) for name in registry.PORTS):
            slug = args.profile[5:] if args.profile.startswith("grok-") else args.profile
            if not args.shared_unit:
                parser.error("--shared-unit <the shared gateway's systemd unit> is required (none: already stopped)")
            move(box, args.profile, args.user or f"hb-{slug.lower()}", {n: getattr(args, n) for n in registry.PORTS},
                 args.shared_unit, args.shared_user)
        else:
            parser.error("give <profile> with all three ports, --undo <profile>, or --render-nginx")
    except (Failed, registry.RegistryError, OSError) as exc:
        print(f"hb-move: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
