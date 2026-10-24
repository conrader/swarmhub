"""peer-bridge: hand one peer message to a bot in another unix account (swapdesign2 §2, swapdesign3 §3 + addendum).

Run only through sudo as root (`/etc/sudoers.d/swarmhub-peer-bridge`, env_reset, !use_pty):

    sudo -n /usr/local/lib/swarmhub/peer-bridge <held|durable|stream> <to> --from-profile <p> [--max-time <s>]

stdin carries `<byte length>\\n<text>`; the text is never in argv (sudo logs argv). For `stream`, EOF on stdin after the
text means cancel: the bridge stops its curl and exits, so no signal ever crosses a uid.

As root it reads only the registry and, for a shared sender, whether the sender's profile folder exists. It then drops
to the recipient's account and runs that account's own skill (`held`, `durable`) or the outbound chat (`stream`), with
the recipient's key read as the recipient and handed to curl on stdin only. The reply stream goes to stdout; `stream`
writes `bridge: session ok` to stderr once the session exists, and its last stderr line is `bridge: http=<code>
rc=<rc>`. The reply leg back to the sender is the sender's own
business (bot-msg's deliver_late, in the sender's account with the sender's key).

The sender is (account, profile): the account from SUDO_UID (never SUDO_USER), the profile from --from-profile.
A dedicated account must name its own registry slug; the shared account (`hermes`) may name any of its own profiles
that is not a registry slug, and is recorded `tier=shared`. Anything else exits 77 before anything is sent.

Exit: 0 done (stream: see the status line); 2 unknown recipient, no skill or no key; 64 usage; 77 refused.
"""
from dataclasses import dataclass
import json
import os
from pathlib import Path
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

import swarmhub_registry as registry

NAME = registry.NAME
TEXT_MAX = 1 << 20
MAX_TIME = 1800
VERBS = ("held", "durable", "stream")
USAGE, REFUSED, UNKNOWN = 64, 77, 2
SKILL = "skills/swarmhub/swarmhub-messages/scripts"


class Stop(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Account:
    name: str
    uid: int
    gid: int
    home: str


class PasswdAccounts:
    """Accounts from the system user database."""

    @staticmethod
    def _account(entry):
        return Account(entry.pw_name, entry.pw_uid, entry.pw_gid, entry.pw_dir)

    def by_uid(self, uid):
        try:
            return self._account(pwd.getpwuid(uid))
        except KeyError:
            return None

    def by_name(self, name):
        try:
            return self._account(pwd.getpwnam(name))
        except KeyError:
            return None


def drop_privileges(account):
    """Become the recipient for good: its groups, gid and uid; refuse if root could be regained."""
    os.initgroups(account.name, account.gid)
    os.setgid(account.gid)
    os.setuid(account.uid)
    if (os.getuid(), os.geteuid(), os.getgid(), os.getegid()) != (account.uid, account.uid, account.gid, account.gid):
        raise Stop(REFUSED, "could not drop to the recipient account")
    try:
        os.setuid(0)
    except PermissionError:
        return
    raise Stop(REFUSED, "root could be regained after the drop")


def parse(argv):
    if len(argv) < 2 or argv[0] not in VERBS:
        raise Stop(USAGE, "usage: peer-bridge <held|durable|stream> <to> --from-profile <p> [--max-time <s>]")
    verb, to, rest, options = argv[0], argv[1], list(argv[2:]), {}
    while rest:
        key = rest.pop(0)
        if key not in ("--from-profile", "--max-time") or not rest or key in options:
            raise Stop(USAGE, f"unexpected argument {key!r}")
        options[key] = rest.pop(0)
    profile = options.get("--from-profile", "")
    if not NAME.fullmatch(to) or not NAME.fullmatch(profile):
        raise Stop(USAGE, "<to> and --from-profile must be profile names")
    max_time = options.get("--max-time", str(MAX_TIME))
    if "--max-time" in options and verb != "stream":
        raise Stop(USAGE, "--max-time is for stream only")
    if not re.fullmatch(r"[0-9]{1,4}", max_time) or not 1 <= int(max_time) <= MAX_TIME:
        raise Stop(USAGE, f"--max-time must be 1-{MAX_TIME} seconds")
    return verb, to, profile, int(max_time)


def shared_profile(account, name):
    """True for a real folder <home>/.hermes/profiles/<name>, with no symlink anywhere below the home. Root answers
    nothing about paths outside the shared account, so a planted link cannot probe another account's 0700 home."""
    home = os.path.realpath(account.home)
    path = os.path.join(home, ".hermes", "profiles", name)
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and os.path.realpath(path) == path


def identify(reg, environ, accounts, profile):
    """(sender profile, tier, caller account) from SUDO_UID and --from-profile, or Stop(77)."""
    raw = environ.get("SUDO_UID", "")
    caller = accounts.by_uid(int(raw)) if raw.isdigit() else None
    if caller is None:
        raise Stop(REFUSED, "no sudo caller")
    slug = registry.by_uid(reg, caller.uid)
    if slug is not None:
        if caller.name != reg["bots"][slug]["user"]:
            raise Stop(REFUSED, "the caller's account does not match the registry")
        if profile != slug:
            raise Stop(REFUSED, f"account {caller.name} sends as {slug}, not {profile}")
        return slug, "dedicated", caller
    shared = accounts.by_name(reg["shared"]["user"])
    if shared is None or caller.uid != shared.uid:
        raise Stop(REFUSED, f"uid {caller.uid} is neither a registered bot nor the shared account")
    if profile in reg["bots"]:
        raise Stop(REFUSED, f"{profile} has its own account; the shared account cannot send as it")
    if profile != "default" and not shared_profile(shared, profile):
        raise Stop(REFUSED, f"the shared account has no profile {profile}")
    return profile, "shared", shared


def recipient(reg, accounts, to):
    """(account, gateway port) of the recipient profile, or Stop(2)."""
    bot = reg["bots"].get(to)
    if bot is not None:
        account = accounts.by_name(bot["user"])
        if account is None or account.uid != bot["uid"]:
            raise Stop(REFUSED, f"the account of {to} does not match the registry")
        return account, bot["gateway_port"]
    shared = accounts.by_name(reg["shared"]["user"])
    if shared is not None and (to == "default" or shared_profile(shared, to)):
        return shared, reg["shared"]["gateway_port"]
    raise Stop(UNKNOWN, f"no bot named {to} on this box")


def read_message(stdin):
    header = b""
    while not header.endswith(b"\n"):
        char = stdin.read(1)
        if not char or len(header) > 8:
            raise Stop(USAGE, "stdin must start with '<byte length>\\n'")
        header += char
    if not re.fullmatch(rb"[0-9]{1,8}\n", header) or not 0 < int(header) <= TEXT_MAX:
        raise Stop(USAGE, f"the text must have 1-{TEXT_MAX} bytes")
    want, data = int(header), b""
    while len(data) < want:
        chunk = stdin.read(want - len(data))
        if not chunk:
            raise Stop(USAGE, "stdin ended before the announced length")
        data += chunk
    return data.decode("utf-8", "replace")


def env_value(path, name):
    """NAME= from an .env like bot-msg reads it: last one wins, `export` and quotes optional, CRs dropped."""
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    pattern, value = re.compile(r"^\s*(?:export\s+)?" + re.escape(name) + "=(.*)$"), None
    for line in lines:
        match = pattern.match(line)
        if match:
            value = match.group(1)
    if value is None:
        return ""
    value = value.replace("\r", "")
    quoted = re.fullmatch(r'"(.*)"\s*', value) or re.fullmatch(r"'(.*)'\s*", value)
    return (quoted.group(1) if quoted else value).rstrip()


class Bridge:
    def __init__(self, account, to, sender, tier, port, python, curl, stdout, stderr):
        self.account, self.to, self.sender, self.tier, self.port = account, to, sender, tier, port
        self.python, self.curl, self.stdout, self.stderr = python, curl, stdout, stderr
        self.hermes = Path(account.home) / ".hermes"
        self.profile = self.hermes if to == "default" else self.hermes / "profiles" / to
        self.env = {"HOME": account.home, "USER": account.name, "LOGNAME": account.name,
                    "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}

    def log(self, verb, result):
        try:
            folder = self.hermes / "swarmhub"
            folder.mkdir(mode=0o700, parents=True, exist_ok=True)
            with open(folder / "peer-bridge.log", "a", encoding="utf-8") as handle:
                handle.write("\t".join((time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), verb, self.sender,
                                        f"tier={self.tier}", self.to, result)) + "\n")
        except OSError:
            pass

    def skill(self, script):
        scripts = (self.hermes / SKILL) if self.to == "default" else (self.profile / SKILL)
        path = scripts / script
        if not self.profile.is_dir() or not path.is_file():
            raise Stop(UNKNOWN, f"{self.to} has no swarmhub-messages skill in its account")
        return str(path)

    def local(self, verb, argv, text):
        """held/durable: the recipient's own skill, as the recipient; its output passes through."""
        self.stderr.flush()
        result = subprocess.run([self.python, "-B", "-E", "-s", *argv], input=text.encode("utf-8"),
                                stdout=self.stdout, stderr=self.stderr, env=self.env, cwd=self.account.home)
        self.log(verb, "ok" if result.returncode == 0 else f"rc={result.returncode}")
        return result.returncode

    def held(self, text):
        return self.local("held", [self.skill("peer-runtime.py"), "hold-stdin", self.sender, self.to, "", self.tier],
                          text)

    def durable(self, text):
        return self.local("durable", [self.skill("swarmctl"), "enqueue-stdin", self.sender, self.to, "", self.tier],
                          text)

    def run_curl(self, key, args, work, stdout):
        config = f'header = "Authorization: Bearer {key}"\n'.encode()
        with open(work / "curl.err", "ab") as errors:
            proc = subprocess.Popen([self.curl, "-sS", "-K", "-", "-D", str(work / "headers"), "-H",
                                     "Content-Type: application/json", *args], stdin=subprocess.PIPE, stdout=stdout,
                                    stderr=errors, env=self.env, cwd=str(work))
        proc.stdin.write(config)
        proc.stdin.close()
        return proc

    @staticmethod
    def http_code(work):
        try:
            codes = re.findall(rb"^HTTP/[0-9.]+ ([0-9]{3})", (work / "headers").read_bytes(), re.M)
        except OSError:
            codes = []
        return codes[-1].decode() if codes else "000"

    def stream(self, text, max_time, stdin):
        key = env_value(self.profile / ".env", "API_SERVER_KEY")
        if not self.profile.is_dir() or not key or re.search(r'["\\\s]', key):
            raise Stop(UNKNOWN, f"{self.to} has no usable API_SERVER_KEY in its account")
        base = f"http://127.0.0.1:{self.port}" + ("" if self.to == "default" else f"/p/{self.to}")
        sid = f"swarmhub-from-{self.sender}"
        shared = " (shared)" if self.tier == "shared" else ""
        # Cancel (stdin EOF, TERM, INT) is watched from the start, so it also ends a session create in progress.
        cancelled, running = threading.Event(), []

        def cancel(*_):
            cancelled.set()
            for proc in running:
                if proc.poll() is None:
                    proc.terminate()

        def watch():
            while os.read(stdin.fileno(), 65536):
                pass
            cancel()
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        threading.Thread(target=watch, daemon=True).start()

        def start(args, out):
            proc = self.run_curl(key, args, work, out)
            running.append(proc)
            if cancelled.is_set():
                cancel()
            return proc
        work = Path(tempfile.mkdtemp(prefix="peer-bridge."))
        try:
            (work / "create.json").write_text(json.dumps({"id": sid, "title": f"From {self.sender}",
                                                          "source": "api_server"}))
            create = start(["-o", str(work / "create.out"), "--max-time", "20", "-H", "Accept: application/json",
                            "-X", "POST", "--data-binary", "@create.json", base + "/api/sessions"], subprocess.DEVNULL)
            rc, code = create.wait(), self.http_code(work)
            if cancelled.is_set():
                return self.status("stream", code, 130, work, " cancelled")  # Nothing was submitted.
            if code not in ("200", "201", "409"):
                return self.status("stream", code, rc, work, " stage=create")
            print("bridge: session ok", file=self.stderr, flush=True)  # bot-msg --no-wait returns from here on.
            (work / "headers").unlink(missing_ok=True)
            if cancelled.is_set():
                return self.status("stream", code, 130, work, " cancelled")  # Before the chat: nothing submitted.
            message = f"[Message from {self.sender} via SwarmHub{shared}]\n{text}"
            (work / "chat.json").write_text(json.dumps({"input": message}, ensure_ascii=False), encoding="utf-8")
            chat = start(["-N", "--max-time", str(max_time), "-H", "Accept: text/event-stream", "-X", "POST",
                          "--data-binary", "@chat.json", f"{base}/api/sessions/{sid}/chat/stream"], self.stdout)
            rc = chat.wait()
            return self.status("stream", self.http_code(work), 130 if cancelled.is_set() else rc, work,
                               " cancelled" if cancelled.is_set() else "")
        finally:
            for item in work.iterdir():
                item.unlink()
            work.rmdir()

    def status(self, verb, code, rc, work, note=""):
        try:
            first = (work / "curl.err").read_text(errors="replace").splitlines()[:1]
        except OSError:
            first = []
        for line in first:
            print("bridge: curl: " + line, file=self.stderr)
        self.log(verb, f"http={code} rc={rc}{note}")
        print(f"bridge: http={code} rc={rc}{note}", file=self.stderr, flush=True)
        return 0


def main(argv, environ, stdin, stdout, stderr, accounts, drop, registry_path=registry.PATH,
         python=sys.executable, curl="/usr/bin/curl"):
    signal.signal(signal.SIGHUP, signal.SIG_IGN)  # A caller's closing terminal never stops a running delivery.
    try:
        if os.geteuid() != 0 or os.getuid() != 0:
            raise Stop(REFUSED, "run it through sudo")
        verb, to, profile, max_time = parse(argv)
        try:
            reg = registry.load(registry_path)
        except registry.RegistryError as exc:
            raise Stop(REFUSED, str(exc)) from None
        sender, tier, caller = identify(reg, environ, accounts, profile)
        account, port = recipient(reg, accounts, to)
        if account.uid == caller.uid:
            raise Stop(USAGE, f"{to} is in the caller's own account; deliver it locally")
        text = read_message(stdin)
        drop(account)
        os.umask(0o077)
        os.chdir(account.home)
        bridge = Bridge(account, to, sender, tier, port, python, curl, stdout, stderr)
        if verb == "held":
            return bridge.held(text)
        if verb == "durable":
            return bridge.durable(text)
        return bridge.stream(text, max_time, stdin)
    except Stop as stop:
        print(f"peer-bridge: {stop}", file=stderr, flush=True)
        return stop.code
