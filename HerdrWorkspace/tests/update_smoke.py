"""Update a workspace server for real: an isolated Herdr Core, a server of its own on its own port and data
folder, a local releases folder, and a throwaway release key. No model calls, nothing outside the temporary folder.

    python3 tests/update_smoke.py "$(command -v hc)" [BUILDS]

The script builds five servers that trust the throwaway key (versions 0.2.0, 0.2.1 and 0.2.3, one that never
starts and one that hangs while starting) and then rebuilds the ordinary one. BUILDS keeps them between runs.
SWARMHUB_UPDATE_SKIP_HANG=1 leaves out the last case, which waits a minute and a half for the watcher.
SWARMHUB_UPDATE_APP_CLIENT names a program that does two of the updates as the Mac app would: `BASE TOKEN VERSION`
checks and installs, `BASE TOKEN upload MANIFEST SIGNATURE PROGRAM` hands a release over.
"""

import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]
# As the server names it (`update::target`): Rust says aarch64 where macOS says arm64.
TARGET = f"{os.uname().machine.replace('arm64', 'aarch64')}-{sys.platform.replace('darwin', 'macos')}"
VARIANTS = {"0.2.0": None, "0.2.1": None, "0.2.2": "start", "0.2.3": None, "0.2.4": "hang"}


def public(key):
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def build(folder, key):
    """One server per version, each trusting `key`; kept between runs until the key file is gone or the source changed."""
    seed = folder / "key"
    # Kept builds are used only while no source file is newer than they are: a check must run the code as it is now.
    sources = max(path.stat().st_mtime for path in [ROOT / "Cargo.toml", ROOT / "Cargo.lock", *(ROOT / "src").rglob("*")])
    kept = all((folder / version).exists() and (folder / version).stat().st_mtime >= sources for version in VARIANTS)
    if seed.exists() and kept:
        return Ed25519PrivateKey.from_private_bytes(seed.read_bytes())
    folder.mkdir(parents=True, exist_ok=True)
    for version, fault in VARIANTS.items():
        env = {**os.environ, "SWARMHUB_UPDATE_PUBLIC_KEY": public(key), "SWARMHUB_BRIDGE_VERSION": version}
        if fault:
            env["SWARMHUB_BRIDGE_TEST_FAULT"] = fault
        subprocess.run(["cargo", "build", "--offline", "--locked"], cwd=ROOT, env=env, check=True)
        shutil.copy(ROOT / "target/debug/swarmhub-herdr", folder / version)
    subprocess.run(["cargo", "build", "--offline", "--locked"], cwd=ROOT, check=True)
    seed.write_bytes(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                       serialization.NoEncryption()))
    seed.chmod(0o600)
    return key


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Releases:
    """A folder served on loopback, as the releases page serves a manifest, its signature and the programs."""

    def __init__(self, folder, builds, key):
        self.folder, self.builds, self.key = folder, builds, key
        folder.mkdir()
        handler = lambda *args: http.server.SimpleHTTPRequestHandler(*args, directory=str(folder))
        http.server.SimpleHTTPRequestHandler.log_message = lambda *args: None
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.address = f"http://127.0.0.1:{self.server.server_address[1]}/"

    def publish(self, version, key=None, damage=False, claim=None):
        """`claim`: the version the manifest names when it is not the program's own."""
        for old in self.folder.iterdir():
            old.unlink()
        program = (self.builds / version).read_bytes()
        name = f"swarmhub-herdr-{claim or version}-{TARGET}"
        manifest = json.dumps({
            "product": "swarmhub-herdr", "version": claim or version, "api": 1, "api_min": 1,
            "released": "2026-11-17", "notes": "A check release.", "base": self.address,
            "assets": [{"target": TARGET, "name": name, "size": len(program),
                        "sha256": hashlib.sha256(program).hexdigest()}],
        }).encode()
        signature = base64.b64encode((key or self.key).sign(manifest))
        (self.folder / name).write_bytes(program[:-1] + bytes([program[-1] ^ 0xFF]) if damage else program)
        (self.folder / "workspace-manifest.json").write_bytes(manifest)
        (self.folder / "workspace-manifest.json.sig").write_bytes(signature)
        return manifest, signature.decode(), program

    def empty(self):
        for old in self.folder.iterdir():
            old.unlink()


class Server:
    def __init__(self, port, token):
        self.base, self.token = f"http://127.0.0.1:{port}", token

    def call(self, path, body=None, raw=None, kind=None, timeout=300):
        data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
        request = urllib.request.Request(self.base + path, data=data, headers={
            "Authorization": f"Bearer {self.token}", "Origin": self.base,
            "Content-Type": kind or "application/json",
            "X-SwarmHub-App": "9.9.9 (99)", "X-SwarmHub-Api": "1"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(request, timeout=timeout) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read() or b"{}")

    def version(self):
        try:
            return self.call("/api/update", timeout=3)[1]["bridge"]["version"]
        except (OSError, KeyError, ValueError):
            return None

    def becomes(self, version, within=40, last=None):
        """Waits until the server answers as `version` and, with `last`, says its last update ended that way."""
        deadline = time.monotonic() + within
        while time.monotonic() < deadline:
            if self.version() == version:
                status = self.call("/api/update")[1]
                if last is None or (status["last"] or {}).get("state") == last:
                    return status
            time.sleep(0.3)
        raise AssertionError(f"the server did not become {version} ({last}) within {within} s: {self.version()}")


def multipart(manifest, signature, program):
    boundary = secrets.token_hex(16)
    body = b""
    for name, data in (("manifest", manifest), ("signature", signature.encode()), ("program", program)):
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{name}\"\r\n"
                 "Content-Type: application/octet-stream\r\n\r\n").encode() + data + b"\r\n"
    return body + f"--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def main(hc, builds):
    # Ended from outside, the script still stops its Herdr Core and its server on the way out.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    key = build(builds, Ed25519PrivateKey.generate())
    with tempfile.TemporaryDirectory(prefix="swarmhub-update-") as temp:
        root = Path(temp)
        for name in ("run", "state", "config/herdr-core", "bin", "agents"):
            (root / name).mkdir(parents=True, mode=0o700)
        core_env = {"HOME": temp, "PATH": "/usr/bin:/bin", "HC_SESSION": "swarmhub-update-test",
                    "XDG_RUNTIME_DIR": str(root / "run"), "XDG_STATE_HOME": str(root / "state"),
                    "XDG_CONFIG_HOME": str(root / "config"), "HC_SOCKET": str(root / "hc.sock"),
                    "LANG": "C.UTF-8"}

        def cli(*args):
            result = subprocess.run([hc, *args], env=core_env, cwd=root, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr
            return result.stdout

        releases = Releases(root / "releases", builds, key)
        program = root / "bin/swarmhub-herdr"
        previous = root / "bin/swarmhub-herdr.previous"
        shutil.copy2(builds / "0.2.0", program)
        port, token, data = free_port(), secrets.token_hex(32), root / "workspace"
        server = Server(port, token)
        # A program that does two of the updates as the Mac app would, when one is named.
        client = os.environ.get("SWARMHUB_UPDATE_APP_CLIENT")
        client_env = {key: value for key, value in os.environ.items() if not key.lower().endswith("_proxy")}
        cli("server", "start")
        process = None
        try:
            # An agent that outlasts the whole check, also on a server whose disk makes it take a quarter of an hour.
            cli("run", "--bg", "--name", "agent", "/bin/sleep", "3600")
            began = time.monotonic()
            process = subprocess.Popen([str(program)], env={
                "HOME": temp, "PATH": "/usr/bin:/bin", "HC_SOCKET": core_env["HC_SOCKET"],
                "SWARMHUB_ACCESS_TOKEN": token, "SWARMHUB_PORT": str(port), "SWARMHUB_DATA_DIR": str(data),
                "SWARMHUB_AGENT_CWD": str(root / "agents"), "SWARMHUB_UPDATE_FEED": releases.address,
            }, stdout=subprocess.DEVNULL)
            started = server.becomes("0.2.0")
            pid = started["pid"]
            assert pid == process.pid and started["can_update"] and not started["previous"] and started["last"] is None
            assert started["app"] == {"version": "9.9.9 (99)", "api": 1}, started
            code, workspace = server.call("/api/workspace")
            # What the server cannot do where it runs: nothing on Linux, an agent's graphical desktop on macOS.
            lacks = [entry["feature"] for entry in workspace["bridge"].pop("unsupported")]
            assert lacks == ([] if sys.platform == "linux" else ["agent_desktop"]), lacks
            assert code == 200 and workspace["bridge"] == {
                "version": "0.2.0", "api": 2, "api_min": 1, "target": TARGET, "updates": True}, workspace
            assert "agent" in cli("ls")
            shown = subprocess.run([str(program), "version"], capture_output=True, text=True).stdout
            assert shown.startswith("swarmhub-herdr 0.2.0 (workspace API 1"), shown

            def untouched(version):
                assert server.version() == version and process.poll() is None
                assert not (root / "bin/swarmhub-herdr.staged").exists()
                assert hashlib.sha256(program.read_bytes()).digest() == hashlib.sha256((builds / version).read_bytes()).digest()

            # Nothing published: the server says it could not download, in a word an app can act on.
            code, answer = server.call("/api/update/check", {})
            assert (code, answer["kind"]) == (502, "feed_unreachable"), answer
            # A release signed with another key is refused, checked or applied.
            releases.publish("0.2.1", key=Ed25519PrivateKey.generate())
            for path in ("/api/update/check", "/api/update/apply"):
                code, answer = server.call(path, {})
                assert (code, answer["kind"]) == (502, "signature"), answer
            untouched("0.2.0")
            # A signed release whose program is not the one it describes is refused.
            releases.publish("0.2.1", damage=True)
            code, answer = server.call("/api/update/apply", {"version": "0.2.1"})
            assert (code, answer["kind"]) == (502, "digest"), answer
            untouched("0.2.0")
            # A signed release whose program says it is another version is refused before anything is replaced.
            releases.publish("0.2.1", claim="0.3.0")
            code, answer = server.call("/api/update/apply", {})
            assert (code, answer["kind"]) == (502, "does_not_run"), answer
            untouched("0.2.0")
            assert not previous.exists()

            # The real thing: checked, applied, and the same process is now the new version.
            releases.publish("0.2.1")
            code, answer = server.call("/api/update/check", {})
            assert code == 200 and answer["available"] and answer["latest"]["version"] == "0.2.1" and answer["latest"]["installable"], answer
            code, answer = server.call("/api/update/apply", {"version": "0.2.0"})
            assert (code, answer["kind"]) == (409, "changed"), answer
            with sqlite3.connect(str(data / "workspace.sqlite3")) as db:
                layout = db.execute("PRAGMA user_version").fetchone()[0]
            code, answer = server.call("/api/update/apply", {"version": "0.2.1"})
            assert code == 200 and answer == {"state": "restarting", "from": "0.2.0", "to": "0.2.1"}, answer
            status = server.becomes("0.2.1", last="done")
            assert status["pid"] == pid and process.poll() is None, "the same process, not a new one"
            assert status["previous"] and status["last"]["from"] == "0.2.0"
            assert subprocess.run([str(previous), "version"], capture_output=True, text=True).stdout.startswith("swarmhub-herdr 0.2.0")
            backup = Path(status["last"]["backup"])
            assert backup.parent == data / "backups" and backup.stat().st_mode & 0o777 == 0o600
            with sqlite3.connect(str(backup)) as db:
                assert db.execute("PRAGMA user_version").fetchone()[0] == layout
            assert not list(data.glob("update-trial-*")), "the journal copy the new program was tried on is gone"
            assert "agent" in cli("ls"), "the agent's terminal is still running in Herdr Core"
            code, workspace = server.call("/api/workspace")
            assert code == 200 and workspace["bridge"]["version"] == "0.2.1", workspace

            # The same release again, or an older one, changes nothing: no replay, no way down.
            for old in ("0.2.1", "0.2.0"):
                releases.publish(old)
                code, answer = server.call("/api/update/apply", {})
                assert code == 200 and answer == {"state": "current", "version": "0.2.1"}, answer
            untouched("0.2.1")

            # Back to the previous version on request.
            code, answer = server.call("/api/update/rollback", {})
            assert code == 200 and answer == {"state": "restarting", "from": "0.2.1", "to": "0.2.0"}, answer
            status = server.becomes("0.2.0", last="rolled_back")
            assert status["pid"] == pid and not status["previous"]
            code, answer = server.call("/api/update/rollback", {})
            assert (code, answer["kind"]) == (409, "no_previous"), answer

            # Handed over by an app, for a server that cannot reach the releases: the same checks, the same result.
            manifest, signature, bytes_ = releases.publish("0.2.1")
            releases.empty()
            body, kind = multipart(manifest, base64.b64encode(Ed25519PrivateKey.generate().sign(manifest)).decode(), bytes_)
            code, answer = server.call("/api/update/upload", raw=body, kind=kind)
            assert (code, answer["kind"]) == (502, "signature"), answer
            body, kind = multipart(manifest, signature, bytes_[:-1] + bytes([bytes_[-1] ^ 0xFF]))
            code, answer = server.call("/api/update/upload", raw=body, kind=kind)
            assert (code, answer["kind"]) == (502, "digest"), answer
            untouched("0.2.0")
            if client:
                # The Mac app's own client hands the release over.
                handed = {"manifest": manifest, "signature": signature.encode(), "program": bytes_}
                for name, data in handed.items():
                    (root / name).write_bytes(data)
                subprocess.run([client, server.base, token, "upload", *(str(root / name) for name in handed)], check=True, timeout=300, env=client_env)
            else:
                body, kind = multipart(manifest, signature, bytes_)
                code, answer = server.call("/api/update/upload", raw=body, kind=kind)
                assert code == 200 and answer["state"] == "restarting", answer
            assert server.becomes("0.2.1", last="done")["pid"] == pid

            # A new version that cannot start gives the process back to the one before it.
            releases.publish("0.2.2")
            code, answer = server.call("/api/update/apply", {"version": "0.2.2"})
            assert code == 200 and answer["to"] == "0.2.2", answer
            status = server.becomes("0.2.1", last="rolled_back")
            assert status["pid"] == pid and process.poll() is None
            assert status["last"]["to"] == "0.2.2" and "never starts" in status["last"]["error"], status
            untouched("0.2.1")
            assert not previous.exists()

            # A good update still works after a failed one.
            releases.publish("0.2.3")
            if client:
                # The Mac app's own client code and state machine, built for this machine, does this update.
                subprocess.run([client, server.base, token, "0.2.3"], check=True, timeout=120, env=client_env)
            else:
                code, answer = server.call("/api/update/apply", {"version": "0.2.3"})
                assert code == 200, answer
            assert server.becomes("0.2.3", last="done")["pid"] == pid

            # A new version that hangs while starting is ended by the watcher, which starts the previous one again.
            if os.environ.get("SWARMHUB_UPDATE_SKIP_HANG") != "1":
                releases.publish("0.2.4")
                code, answer = server.call("/api/update/apply", {"version": "0.2.4"})
                assert code == 200 and answer["to"] == "0.2.4", answer
                print("waiting for the watcher (about 90 s)…", flush=True)
                status = server.becomes("0.2.3", within=130, last="rolled_back")
                assert status["pid"] != pid, "a new process: the watcher ended the hanging one"
                assert process.wait(timeout=5) != 0
                assert "did not start serving in time" in status["last"]["error"], status
                assert hashlib.sha256(program.read_bytes()).digest() == hashlib.sha256((builds / "0.2.3").read_bytes()).digest()
                assert "agent" in cli("ls")
                os.kill(status["pid"], 15)
            print(f"update smoke: ok ({time.monotonic() - began:.0f} s with the agent running)")
        finally:
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            cli("server", "stop")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    keep = Path(sys.argv[2]) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="swarmhub-update-builds-") as scratch:
        main(sys.argv[1], keep or Path(scratch))
