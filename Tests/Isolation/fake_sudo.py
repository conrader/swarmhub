"""Test stand-in for `sudo -n <peer-bridge> …` (Tests/Isolation only; never installed).

The sandbox (sbtest in a user + PID namespace) maps a single uid, so accounts are fixtures: the caller's uid comes from
FAKE_UID, as sudo would put the real uid in SUDO_UID. Like sudoers' env_reset, the bridge gets a fresh environment
(FAKE_SUDO_USER stands in for a forged SUDO_USER). It runs in its own session, so a kill of the caller's process group
cannot reach it, as a root process would be out of reach.
"""
import os
import sys
from pathlib import Path

args = sys.argv[1:]
if len(args) < 2 or args[0] != "-n" or args[1] != os.environ.get("SWARMHUB_PEER_BRIDGE"):
    print("sudo: a password is required", file=sys.stderr)
    sys.exit(1)
try:
    os.setsid()
except OSError:
    pass
env = {"PATH": "/usr/bin:/bin", "SUDO_UID": os.environ.get("FAKE_UID", ""), "SUDO_COMMAND": " ".join(args[1:]),
       "SUDO_USER": os.environ.get("FAKE_SUDO_USER", ""), "TMPDIR": os.environ.get("FAKE_TMP", "/tmp")}
launcher = str(Path(__file__).with_name("bridge_launcher.py"))
os.execve(sys.executable, [sys.executable, "-I", "-B", launcher, os.environ["FAKE_ACCOUNTS"], *args[1:]], env)
