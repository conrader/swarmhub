"""A throwaway box for the isolation tests: accounts hermes (shared: s1, s2), hb-a (bot a), hb-b (bot b) and hb-x (in
no registry), each with its own home, profile .env, key and stub gateway, a root-owned registry and the bridge files
installed under <root>/usr/local/lib/swarmhub/ exactly as hb-move installs them.

Run only inside the sandbox (sim/ISOLATION.md): every pid signalled here is one this suite started, found in the
suite's own PID namespace by its command line naming this world's root.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SKILL = REPO / "Resources/Skills/swarmhub-messages/scripts"
OPS = REPO / "ops/isolation"
SKILL_PATH = "skills/swarmhub/swarmhub-messages/scripts"
KEYS = {"a": "sk-a-11aa22bb33cc44dd", "b": "sk-b-55ee66ff77001122", "s1": "sk-s1-3344556677889900",
        "s2": "sk-s2-aabbccddeeff0011", "hermes-default": "sk-hd-99887766554433"}
UIDS = {"hermes": 2000, "hb-a": 2001, "hb-b": 2002, "hb-x": 2009}
PROFILES = {"hermes": ["s1", "s2"], "hb-a": ["a"], "hb-b": ["b"], "hb-x": []}
OWNER = {"a": "hb-a", "b": "hb-b", "s1": "hermes", "s2": "hermes"}
STUBS = ("a", "b", "shared", "s1", "s2")


class World:
    def __init__(self, registry=True):
        self.root = Path(tempfile.mkdtemp(prefix="iso-world.", dir=os.environ.get("TMPDIR")))
        self.lib = self.root / "usr/local/lib/swarmhub"
        self.lib.mkdir(parents=True)
        for name in ("peer-bridge", "peer_bridge.py", "swarmhub_registry.py"):
            shutil.copy2(OPS / name, self.lib / name)
        self.bridge = str(self.lib / "peer-bridge")
        (self.root / "tmp-bridge").mkdir()
        self.accounts = {name: {"uid": uid, "gid": uid, "home": str(self.root / "home" / name)}
                         for name, uid in UIDS.items()}
        (self.root / "accounts.json").write_text(json.dumps(self.accounts))
        (self.root / "all-keys").write_text("".join(f"{who} {key}\n" for who, key in KEYS.items()))
        self.stub_proc = None
        try:
            self.start_stubs()
            for account, profiles in PROFILES.items():
                hermes = self.home(account) / ".hermes"
                hermes.mkdir(parents=True)
                (self.root / f"tmp-{account}").mkdir()
                for profile in profiles:
                    self.make_profile(account, profile)
                if account == "hermes":
                    (hermes / ".env").write_text(f"API_SERVER_KEY={KEYS['hermes-default']}\n")
            if registry:
                self.write_registry()
        except BaseException:
            self.close()
            raise

    # -- layout --------------------------------------------------------------------------------------------------
    def home(self, account):
        return Path(self.accounts[account]["home"])

    def profile(self, profile):
        return self.home(OWNER[profile]) / ".hermes/profiles" / profile

    def make_profile(self, account, profile):
        folder = self.home(account) / ".hermes/profiles" / profile
        shutil.copytree(SKILL, folder / SKILL_PATH)
        (folder / ".env").write_text(f"API_SERVER_KEY={KEYS[profile]}\nAPI_SERVER_PORT={self.port(profile)}\n")

    def write_registry(self, data=None):
        folder = self.root / "etc/swarmhub"
        folder.mkdir(parents=True, exist_ok=True)
        folder.chmod(0o755)
        data = data or {"version": 1, "shared": {"user": "hermes", "gateway_port": self.port("shared")},
                        "bots": {"a": {"user": "hb-a", "uid": 2001, "gateway_port": self.port("a"),
                                       "receiver_port": 20001, "control_port": 20002},
                                 "b": {"user": "hb-b", "uid": 2002, "gateway_port": self.port("b"),
                                       "receiver_port": 20003, "control_port": 20004}}}
        path = folder / "bots.json"
        path.write_text(json.dumps(data))
        path.chmod(0o644)
        return path

    @property
    def registry(self):
        return self.root / "etc/swarmhub/bots.json"

    # -- stubs ---------------------------------------------------------------------------------------------------
    def start_stubs(self):
        folders = []
        for stub in STUBS:
            folder = self.root / "gw" / stub
            folder.mkdir(parents=True)
            keys = {"a": {"a": KEYS["a"], "default": KEYS["a"]}, "b": {"b": KEYS["b"], "default": KEYS["b"]},
                    "shared": {"s1": KEYS["s1"], "s2": KEYS["s2"], "default": KEYS["hermes-default"]},
                    "s1": {"default": KEYS["s1"], "s1": KEYS["s1"]}, "s2": {"default": KEYS["s2"], "s2": KEYS["s2"]}}
            (folder / "keys").write_text("".join(f"{p} {k}\n" for p, k in keys[stub].items()))
            folders.append(str(folder))
        self.stub_proc = subprocess.Popen(["/usr/bin/python3", "-I", "-B", str(HERE / "stub_gateway.py"),
                                           str(self.root / "all-keys"), *folders], stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while not all((Path(f) / "port").exists() for f in folders):
            if time.monotonic() > deadline or self.stub_proc.poll() is not None:
                raise RuntimeError("stub gateways did not start")
            time.sleep(0.05)

    def port(self, stub):
        return int((self.root / "gw" / stub / "port").read_text())

    def mode(self, stub, value):
        (self.root / "gw" / stub / "mode").write_text(value)

    def requests(self, stub):
        try:
            return (self.root / "gw" / stub / "requests").read_text().splitlines()
        except FileNotFoundError:
            return []

    def chats(self, stub):
        found = sorted((self.root / "gw" / stub).glob("input.*"), key=lambda p: int(p.suffix[1:]))
        return [json.loads(p.read_text()) for p in found]

    # -- running -------------------------------------------------------------------------------------------------
    def env(self, account, **extra):
        env = {"HOME": str(self.home(account)), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.root / f"tmp-{account}"),
               "FAKE_UID": str(UIDS[account]), "PYTHONPATH": str(HERE / "fakeuid"), "PYTHONDONTWRITEBYTECODE": "1",
               "SWARMHUB_REGISTRY": str(self.registry), "SWARMHUB_SUDO": str(HERE / "fake-sudo"),
               "SWARMHUB_PEER_BRIDGE": self.bridge, "FAKE_ACCOUNTS": str(self.root / "accounts.json"),
               "FAKE_TMP": str(self.root / "tmp-bridge")}
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def bot_msg_argv(self, sender, *args, shell="/bin/sh"):
        script = self.profile(sender) / SKILL_PATH / "bot-msg"
        return [shell, str(script), *args]

    def bot_msg(self, sender, *args, timeout=60, env=None, **extra):
        account = OWNER[sender]
        return subprocess.run(self.bot_msg_argv(sender, *args), env=env or self.env(account, **extra),
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def start_bot_msg(self, sender, *args, **extra):
        return subprocess.Popen(self.bot_msg_argv(sender, *args), env=self.env(OWNER[sender], **extra),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                stdin=subprocess.DEVNULL, start_new_session=True)

    def bridge_call(self, account, argv, text=b"hello", sudo_user=None, stdin=None):
        """peer-bridge through fake sudo as `account` (its FAKE_UID), the way bot-msg calls it."""
        env = self.env(account)
        if sudo_user:
            env["FAKE_SUDO_USER"] = sudo_user
        data = stdin if stdin is not None else b"%d\n%s" % (len(text), text)
        return subprocess.run([str(HERE / "fake-sudo"), "-n", self.bridge, *argv], env=env, input=data,
                              capture_output=True, timeout=60)

    def log(self, account):
        try:
            return (self.home(account) / ".hermes/swarmhub/bot-messages.log").read_text().splitlines()
        except FileNotFoundError:
            return []

    def bridge_log(self, account):
        try:
            return (self.home(account) / ".hermes/swarmhub/peer-bridge.log").read_text().splitlines()
        except FileNotFoundError:
            return []

    def query(self, account, database, sql):
        path = self.home(account) / ".hermes/swarmhub" / database
        if not path.exists():
            return []
        with sqlite3.connect(path) as db:
            return db.execute(sql).fetchall()

    @staticmethod
    def until(predicate, timeout=15, step=0.1):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(step)
        return predicate()

    def processes(self, needle):
        """(pid, command line) of live, non-zombie processes in this namespace whose argv mentions `needle`."""
        found = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                if (entry / "stat").read_text().rsplit(")", 1)[1].split()[0] == "Z":
                    continue
                argv = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            except (OSError, IndexError):
                continue
            if needle in argv:
                found.append((int(entry.name), argv))
        return found

    @staticmethod
    def descendant(pid):
        seen = set()
        while pid > 1 and pid not in seen:
            seen.add(pid)
            try:
                pid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                return False
            if pid == os.getpid():
                return True
        return False

    def files_containing(self, folder, secret):
        hits = []
        for path in Path(folder).rglob("*"):
            try:
                if path.is_file() and not path.is_symlink() and secret.encode() in path.read_bytes():
                    hits.append(str(path))
            except OSError:
                pass
        return hits

    def close(self):
        if self.stub_proc is not None and self.stub_proc.poll() is None:
            self.stub_proc.terminate()
            self.stub_proc.wait(5)
        # Leftovers of this world that are still our descendants (a stream a failed test left running). Detached
        # recovery workers were adopted by the namespace's init: the signal guard refuses them, and they end with the
        # namespace; their state folder goes below, and a removed state folder is never recreated.
        for pid, _ in self.processes(str(self.root)):
            if not self.descendant(pid):
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        shutil.rmtree(self.root, ignore_errors=True)
