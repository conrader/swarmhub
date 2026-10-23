"""Supervision of the off-app alert service (`swarmctl alerts run`), installed the way the webhook receiver is:

Linux: systemd user unit ~/.config/systemd/user/swarmhub-alerts.service (Restart=on-failure, journald). Where no
lingering systemd user manager answers (Hermes as a system service): a fallback. The service itself holds the
account's lock file, so no separate supervisor is needed; a marker records the fallback and the peer plugin starts it
again at each gateway start (`resume`); removing the marker stops it within one tick. macOS: LaunchAgent
com.swarmhub.alerts, logging to ~/Library/Logs/SwarmHub/alerts.log. Never when HOME is not the account's home.
The unit holds no setting and no secret; the service prints no alert text, so neither the unit nor its log can leak one.
A skill update needs no reinstall: the service re-executes itself when its code on disk changes.
"""
import json
import os
from pathlib import Path
import plistlib

from swarm_intake import write_private
import swarm_store as store
import swarm_webhook_receiver as receiver

NAME = "swarmhub-alerts.service"
LABEL = "com.swarmhub.alerts"
HERE = Path(__file__).resolve().parent
# The receiver's service-manager helpers, looked up at call time (tests patch `receiver.run` once for both services).
def manager():
    return receiver.manager()


def run(*args):
    return receiver.run(*args)


def domain():
    return receiver.domain()


def folder():
    path = store.state() / "alerts"
    path.mkdir(mode=0o700, exist_ok=True)
    path.chmod(0o700)
    return path


def fallback_paths():
    return {"marker": folder() / "service.supervised", "lock": folder() / "service.lock",
            "log": folder() / "service.log"}


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
        return str(Path.home() / "Library/Logs/SwarmHub/alerts.log")
    return str(fallback_paths()["log"])


def systemd_text(python, swarmctl):
    return f"""# Swarm Hub off-app alerts; written by `swarmctl alerts panel install`.
# swarmctl: {swarmctl}
[Unit]
Description=Swarm Hub off-app alerts
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
ExecStart={python} -B {swarmctl} alerts run
Environment=PYTHONDONTWRITEBYTECODE=1
UMask=0077
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes

[Install]
WantedBy=default.target
"""


def launchd_text(python, swarmctl):
    return plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [python, "-B", str(swarmctl), "alerts", "run"],
        "EnvironmentVariables": {"PYTHONDONTWRITEBYTECODE": "1"},
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "StandardOutPath": log_hint("launchd"),
        "StandardErrorPath": log_hint("launchd"),
    }).decode()


def fallback_running():
    """The pid holding the service lock (0 if unreadable), else None."""
    import fcntl
    try:
        handle = fallback_paths()["lock"].open("r")
    except FileNotFoundError:
        return None
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            text = handle.read().strip()
            return int(text) if text.isdigit() else 0
        fcntl.flock(handle, fcntl.LOCK_UN)
        return None


def start_fallback(python):
    paths = fallback_paths()
    paths["marker"].write_text(json.dumps({"python": python}) + "\n")
    if fallback_running() is None:
        spawn(python)


def spawn(python):
    paths = fallback_paths()
    if paths["log"].exists() and paths["log"].stat().st_size > 1_000_000:
        os.replace(paths["log"], paths["log"].with_name(paths["log"].name + ".1"))
    import subprocess
    import threading
    with paths["log"].open("ab") as log:
        child = subprocess.Popen([python, "-B", str(HERE / "swarmctl"), "alerts", "run", "--fallback"], stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True, close_fds=True)
    threading.Thread(target=child.wait, daemon=True).start()  # Reaped while a long-lived gateway owns us.


def install():
    """Write the unit if it changed, enable and start it; the fallback where no user manager is usable."""
    kind = manager()
    path = unit_path(kind)
    if path is None:
        raise ValueError("no supported service manager for this account here (systemd user units or launchd, with HOME as "
                         "the account's home); run `swarmctl alerts run` under your own supervisor")
    if kind == "systemd" and not receiver.lingering():
        return supervised(path)
    text = (systemd_text if kind == "systemd" else launchd_text)(receiver.interpreter(), HERE / "swarmctl")
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
        steps += [("systemctl", "--user", "enable", NAME), ("systemctl", "--user", "restart" if changed else "start", NAME)]
    else:
        loaded = run("launchctl", "print", f"{domain()}/{LABEL}")[0] == 0
        steps = [("launchctl", "bootout", f"{domain()}/{LABEL}")] if changed and loaded else []
        steps += [("launchctl", "bootstrap", domain(), str(path))] if changed or not loaded else []
        steps += [("launchctl", "kickstart", f"{domain()}/{LABEL}")]
    for step in steps:
        code, output = run(*step)
        if code != 0 and kind == "systemd" and (code == 127 or any(sign in output for sign in receiver.NO_USER_MANAGER)):
            return supervised(path)
        if code != 0:
            raise ValueError(f"{' '.join(step[:3])} failed ({code}): {output}")
    fallback_paths()["marker"].unlink(missing_ok=True)  # The user manager owns it now; a fallback exits within a tick.
    return {"manager": kind, "changed": changed}


def supervised(path):
    if path.exists():
        run("systemctl", "--user", "disable", "--now", NAME)
        path.unlink()
        run("systemctl", "--user", "daemon-reload")
    start_fallback(receiver.interpreter())
    return {"manager": "supervisor", "changed": True}


def uninstall():
    kind = manager()
    removed = fallback_paths()["marker"].exists()
    fallback_paths()["marker"].unlink(missing_ok=True)
    path = unit_path(kind)
    if path is not None and path.exists():
        if kind == "systemd":
            run("systemctl", "--user", "disable", "--now", NAME)
        else:
            run("launchctl", "bootout", f"{domain()}/{LABEL}")
        path.unlink()
        if kind == "systemd":
            run("systemctl", "--user", "daemon-reload")
        removed = True
    return {"manager": kind, "removed": removed}


def status():
    """How the service is installed. Whether it runs is the heartbeat's call (`swarm_alerts.status`)."""
    kind = manager()
    path = unit_path(kind)
    if kind != "none" and not (path and path.exists()) and fallback_paths()["marker"].exists():
        return {"manager": "supervisor", "installed": True, "logs": log_hint("none"),
                "service": "supervised" if fallback_running() is not None else "stopped"}
    if kind == "systemd" and path.exists():
        lines = run("systemctl", "--user", "is-active", NAME)[1].splitlines()
        return {"manager": kind, "installed": True, "service": lines[-1] if lines else "unknown", "logs": log_hint(kind)}
    if kind == "launchd" and path.exists():
        loaded = run("launchctl", "print", f"{domain()}/{LABEL}")[0] == 0
        return {"manager": kind, "installed": True, "service": "loaded" if loaded else "not loaded", "logs": log_hint(kind)}
    return {"manager": kind, "installed": False, "service": "not installed", "logs": log_hint(kind)}


def resume():
    """Gateway start: bring a recorded fallback back after a reboot. Never raises into the plugin."""
    try:
        marker = store.state() / "alerts" / "service.supervised"
        if marker.exists() and fallback_running() is None:
            spawn(json.loads(marker.read_text()).get("python") or receiver.interpreter())
    except Exception:  # noqa: BLE001  A malformed marker must never fail the gateway's plugin load.
        pass
