"""Supervised webhook receiver: one per-user service that keeps `swarmctl webhook serve` running on loopback.

Linux: a systemd user unit (~/.config/systemd/user/swarmhub-webhook.service), restarted on failure, logging to the
user journal; where no systemd user manager is reachable (Hermes as a system service without lingering), the
lock-guarded fallback supervisor in swarm_webhook_supervisor.py, resumed at each gateway start. macOS: a LaunchAgent (~/Library/LaunchAgents/com.swarmhub.webhook.plist), restarted on failure,
logging to ~/Library/Logs/SwarmHub/webhook-receiver.log. Installing is idempotent: the file is rewritten only when
its text changes (a new skill version changes it), and an unchanged running service is left alone. The receiver
binds 127.0.0.1 only; exposing it is the owner's reverse proxy (docs/webhooks-exposure.md). The unit carries no key
and the receiver logs no request, so neither the service file nor its log can hold a secret.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

from swarm_intake import write_private
import swarm_webhook_supervisor as fallback

NAME = "swarmhub-webhook.service"
LABEL = "com.swarmhub.webhook"
PORT = 8745
HEALTH = "/swarmhub/webhook/health"
SERVICE = "swarmhub-webhook"
HERE = Path(__file__).resolve().parent
# The modules the receiver loads; their digest is in the unit, so a skill update restarts it on the next install.
CODE = ("swarmctl", "swarm_control.py", "swarm_webhook.py", "swarm_delivery.py", "swarm_store.py", "swarm_policy.py",
        "swarm_intake.py", "swarm_webhook_receiver.py", "swarm_webhook_supervisor.py")
NO_USER_MANAGER = ("Failed to connect to bus", "No medium found", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")


def manager():
    forced = os.environ.get("SWARMHUB_RECEIVER_MANAGER", "")
    if forced in ("systemd", "launchd", "none"):
        return forced
    try:
        own = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    except KeyError:
        own = None
    if own != Path.home().resolve():
        return "none"  # A temporary HOME (tests, sandboxes) never reaches the account's real service manager.
    return {"linux": "systemd", "darwin": "launchd"}.get(sys.platform, "none")


def unit_path(kind=None):
    kind = kind or manager()
    if kind == "systemd":
        base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        return Path(base) / "systemd/user" / NAME
    if kind == "launchd":
        return Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    return None


def log_hint(kind=None):
    kind = kind or manager()
    if kind == "systemd":
        return "journalctl --user -u " + NAME
    if kind == "launchd":
        return str(Path.home() / "Library/Logs/SwarmHub/webhook-receiver.log")
    return ""


def interpreter():
    # The system Python, not Hermes' venv: the receiver is standard-library only and must outlive Hermes updates.
    for candidate in ("/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"):
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("python3") or sys.executable


def current_target(kind):
    """The swarmctl an installed unit already runs, if it still exists; batches over profiles then keep one copy."""
    path = unit_path(kind)
    try:
        text = path.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        for head, tail in (("# swarmctl: ", ""), ("<!-- swarmctl: ", " -->")):
            if line.startswith(head) and line.endswith(tail):
                target = Path(line[len(head):len(line) - len(tail)].strip())
                return target if target.name == "swarmctl" and target.is_file() else None
    return None


def digest(folder):
    hasher = hashlib.sha256()
    for name in CODE:
        try:
            hasher.update(name.encode() + b"\0" + (folder / name).read_bytes())
        except OSError:
            hasher.update(name.encode() + b"\0missing")
    return hasher.hexdigest()[:16]


def systemd_text(python, swarmctl, port=PORT):
    return f"""# Swarm Hub webhook receiver (loopback {port}); written by `swarmctl webhook receiver install`.
# swarmctl: {swarmctl}
# code: {digest(swarmctl.parent)}
[Unit]
Description=Swarm Hub webhook receiver (127.0.0.1:{port})
After=network.target

[Service]
Type=simple
ExecStart={python} -B {swarmctl} webhook serve {port}
Environment=PYTHONDONTWRITEBYTECODE=1
UMask=0077
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=default.target
"""


def launchd_text(python, swarmctl, port=PORT):
    body = plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [python, "-B", str(swarmctl), "webhook", "serve", str(port)],
        "EnvironmentVariables": {"PYTHONDONTWRITEBYTECODE": "1"},
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 5,
        "ProcessType": "Background",
        "StandardOutPath": log_hint("launchd"),
        "StandardErrorPath": log_hint("launchd"),
    }).decode()
    head = f"<!-- swarmctl: {swarmctl} -->\n<!-- code: {digest(swarmctl.parent)} -->\n"
    # Comments go after the XML declaration; current_target() reads the swarmctl line from either format.
    first, rest = body.split("\n", 1)
    return first + "\n" + head + rest


def run(*args):
    env = dict(os.environ)
    runtime = f"/run/user/{os.getuid()}"
    if args[0] == "systemctl" and not env.get("XDG_RUNTIME_DIR") and os.path.isdir(runtime):
        env["XDG_RUNTIME_DIR"] = runtime  # A gateway started by the system manager lacks it; the user manager is there.
    try:
        done = subprocess.run(list(args), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30, env=env)
    except FileNotFoundError:
        return 127, args[0] + " not found"
    except subprocess.TimeoutExpired:
        return 124, args[0] + " timed out"
    return done.returncode, (done.stdout + done.stderr).strip()[-400:]


def domain():
    return f"gui/{os.getuid()}"


def install(port=PORT):
    """Write the service file if it changed, then enable and start it. Raises ValueError when the manager refuses."""
    kind = manager()
    path = unit_path(kind)
    if path is None:
        raise ValueError("no supported service manager for this account here (systemd user units or launchd, with HOME as "
                         "the account's home); run `swarmctl webhook serve` under your own supervisor")
    target = current_target(kind) or HERE / "swarmctl"
    text = (systemd_text if kind == "systemd" else launchd_text)(interpreter(), target, port)
    try:
        changed = path.read_text() != text
    except OSError:
        changed = True
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == "launchd":
            Path(log_hint(kind)).parent.mkdir(parents=True, exist_ok=True)
        write_private(path, text.encode())
    if kind == "systemd":
        steps = [("systemctl", "--user", "daemon-reload")] if changed else []
        steps += [("systemctl", "--user", "enable", NAME),
                  ("systemctl", "--user", "restart" if changed else "start", NAME)]
    else:
        loaded = run("launchctl", "print", f"{domain()}/{LABEL}")[0] == 0
        steps = [("launchctl", "bootout", f"{domain()}/{LABEL}")] if changed and loaded else []
        steps += [("launchctl", "bootstrap", domain(), str(path))] if changed or not loaded else []
        steps += [("launchctl", "kickstart", f"{domain()}/{LABEL}")]
    for step in steps:
        code, output = run(*step)
        if code != 0 and kind == "systemd" and (code == 127 or any(sign in output for sign in NO_USER_MANAGER)):
            return supervised(path, port)
        if code != 0:
            raise ValueError(f"{' '.join(step[:3])} failed ({code}): {output}")
    if fallback.enabled():
        fallback.stop()  # The user manager owns it now; the fallback hands the port over within seconds.
    return dict(status(port), changed=changed)


def supervised(path, port):
    """No systemd user manager for this account: drop the unused unit and run the fallback supervisor instead."""
    path.unlink(missing_ok=True)
    fallback.start(interpreter(), port)
    for _ in range(30):
        if probe(port, timeout=0.5):
            break
        time.sleep(0.1)
    return dict(status(port), changed=True)


def uninstall():
    kind = manager()
    path = unit_path(kind)
    if path is None:
        return {"manager": kind, "removed": False}
    if fallback.enabled():
        fallback.stop()
        return {"manager": "supervisor", "removed": True}
    if kind == "systemd":
        run("systemctl", "--user", "disable", "--now", NAME)
    else:
        run("launchctl", "bootout", f"{domain()}/{LABEL}")
    removed = path.exists()
    if removed:
        path.unlink()
    if kind == "systemd":
        run("systemctl", "--user", "daemon-reload")
    return {"manager": kind, "removed": removed}


def probe(port=PORT, timeout=2):
    """True only when our receiver answers the health check; another program on the port does not count."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # Loopback never goes through a proxy.
    try:
        with opener.open(f"http://127.0.0.1:{int(port)}{HEALTH}", timeout=timeout) as response:
            return json.loads(response.read(4096) or b"{}").get("service") == SERVICE
    except (OSError, ValueError, urllib.error.URLError):
        return False


def status(port=PORT):
    kind = manager()
    path = unit_path(kind)
    installed = bool(path and path.exists())
    logs = log_hint(kind)
    if kind != "none" and not installed and fallback.enabled():
        kind, installed, path, logs = "supervisor", True, fallback.paths()["marker"], str(fallback.paths()["log"])
        service = "supervised" if fallback.holder() is not None else "stopped"
    elif kind == "systemd" and installed:
        service = run("systemctl", "--user", "is-active", NAME)[1].splitlines()[-1:] or ["unknown"]
        service = service[0]
    elif kind == "launchd" and installed:
        service = "loaded" if run("launchctl", "print", f"{domain()}/{LABEL}")[0] == 0 else "not loaded"
    else:
        service = "not installed"
    running = probe(port)
    if running:
        detail = f"Receiving on 127.0.0.1:{port}."
    elif kind == "none":
        detail = f"Nothing answers on 127.0.0.1:{port}, and this box has no service manager Swarm Hub can use; run `swarmctl webhook serve` under your own supervisor."
    elif not installed:
        detail = "The receiver is not installed on this box. Start it from the app or run `swarmctl webhook receiver install`."
    else:
        detail = f"The receiver is installed ({service}) but not answering on 127.0.0.1:{port}. Logs: {logs}"
    return {"manager": kind, "installed": installed, "service": service, "running": running, "port": port,
            "listen": f"127.0.0.1:{port}", "unit": str(path) if path else "", "logs": logs, "detail": detail}


def ensure():
    """The setup path's call: install, say on stderr when it is not running, never fail the skill installation."""
    try:
        result = install()
    except (OSError, ValueError) as exc:
        result = {"running": False, "detail": "webhook receiver not started: " + str(exc)}
    if not result.get("running"):
        print("peer-runtime: " + result.get("detail", "webhook receiver not running"), file=sys.stderr)
    return result


def resume():
    """Plugin load (gateway start): restart a recorded fallback supervisor; systemd and launchd restart their own."""
    fallback.resume()
