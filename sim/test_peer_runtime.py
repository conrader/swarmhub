"""Offline P01/P02/P03 regressions using the shipped scripts and synthetic SSE.

No provider, gateway deployment or Swift execution is claimed by these tests.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MSG = ROOT / "Resources/Skills/swarmhub-messages/scripts/bot-msg"
RUNTIME = MSG.with_name("peer-runtime.py")
sys.path.insert(0, str(RUNTIME.parent))
JOB = ROOT / "Resources/Skills/swarmhub-coding/scripts/code-job"
spec = importlib.util.spec_from_file_location("peer_runtime", RUNTIME)
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)


def children_by_home(home):
    """Pids matching HOME, plus conservative descendant candidates on macOS.

    Linux reads ``/proc/<pid>/environ``. macOS has no /proc: one ``ps -E``
    listing carries the environment after each command. The BSD ``e`` spelling
    is a fallback for procps, which rejects -E. Dashless ``axeww`` also requests
    the environment on macOS: it selects legacy BSD option parsing.
    With SIP, macOS withholds the environment of restricted platform binaries
    (/bin/sleep, /bin/sh) from other processes. Include live descendants seen in
    both the plain and environment listings regardless of command or HOME:
    exec between snapshots must not produce false clean results. A withheld
    orphan is invisible. Discovery failures, including the plain listing,
    must not masquerade as successful cleanup.
    """
    marker = "HOME=" + str(home)
    if Path("/proc/self/environ").exists():
        return _pids_by_home_proc(marker.encode(), os.getpid())
    return _children_by_home_ps(marker, os.getpid())


def _children_by_home_ps(marker, me):
    plain = _plain_ps_rows()
    readable = False
    for flags in ("-axEww", "axeww"):
        try:
            result = subprocess.run(["/bin/ps", flags, "-o", "pid=,command="], capture_output=True,
                                    text=True, timeout=10, check=False)
        except (OSError, subprocess.SubprocessError):
            continue
        if result.returncode != 0 or not result.stdout.strip():
            continue
        readable = True
        found = _pids_by_home_ps(result.stdout, marker, me)
        found += [pid for pid in _live_descendants(result.stdout, plain, me) if pid not in found]
        if found:
            return found
    if not readable:
        # Never include ps output: it contains other processes' environments.
        raise RuntimeError("process discovery failed: neither ps -E nor its BSD e fallback returned a listing")
    return []


def _plain_ps_rows():
    """{pid: (ppid, command)} for live (non-zombie) processes, without environments."""
    try:
        result = subprocess.run(["/bin/ps", "axww", "-o", "pid=,ppid=,stat=,command="], capture_output=True,
                                text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        result = None
    rows = {}
    for line in result.stdout.splitlines() if result is not None and result.returncode == 0 else ():
        fields = line.split(None, 3)
        if len(fields) < 3 or not (fields[0].isdigit() and fields[1].isdigit()):
            rows = {}  # Unparseable: unknown, not empty.
            break
        if not fields[2].startswith("Z"):
            rows[int(fields[0])] = (int(fields[1]), fields[3].rstrip() if len(fields) > 3 else "")
    if not rows:
        raise RuntimeError("process discovery failed: the plain ps listing was unavailable or unparseable")
    return rows


def _live_descendants(listing, plain, me):
    """Descendants seen in both snapshots, using plain ps for liveness/ancestry.

    Commands and environments can change during exec; neither can exclude a
    descendant. Requiring its PID in both listings excludes the short-lived ps
    probes themselves, which would otherwise make cleanup always look dirty.
    """
    found = []
    for line in listing.splitlines():
        fields = line.split(None, 1)
        if not fields or not fields[0].isdigit():
            continue
        pid = int(fields[0])
        if pid == me or pid not in plain:
            continue
        parent, seen = plain[pid][0], {pid}
        while parent != me and parent in plain and parent not in seen:
            seen.add(parent)
            parent = plain[parent][0]
        if parent == me:
            found.append(pid)
    return found


def _pids_by_home_proc(marker, me):
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) == me:
            continue
        try:
            if marker in (entry / "environ").read_bytes().split(b"\0"):
                found.append(int(entry.name))
        except OSError:
            continue
    return found


def _pids_by_home_ps(listing, marker, me):
    """``ps -E -o pid=,command=`` rows, preserving spaces in HOME values."""
    found = []
    home = re.compile(r"(?<!\S)" + re.escape(marker) + r"(?=\s+[A-Za-z_][A-Za-z0-9_]*=|\s*$)")
    for line in listing.splitlines():
        fields = line.split(None, 1)
        if len(fields) > 1 and fields[0].isdigit() and int(fields[0]) != me and home.search(fields[1]):
            found.append(int(fields[0]))
    return found


class PeerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMPDIR": str(self.home), "PYTHONDONTWRITEBYTECODE": "1",
                    "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
        self.patcher = patch.dict(os.environ, self.env, clear=True)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.addCleanup(self.stop_background)
        self.keys = {"sender": "synthetic-sender", "worker": "synthetic-worker",
                     "recipient": "synthetic-recipient", "coordinator": "synthetic-coordinator"}
        for name, key in self.keys.items():
            folder = self.home / ".hermes/profiles" / name
            folder.mkdir(parents=True)
            (folder / ".env").write_text(f"API_SERVER_KEY={key}\n")
        self.reply = "NO_REPLY"
        self.status = 200
        self.terminal = True
        self.failed = False
        self.curl_state = self.home / "curl-state"
        self.curl_state.mkdir()
        self.release = self.curl_state / "release"
        self.release.touch()
        stub_bin = self.home / "stub-bin"
        stub_bin.mkdir()
        (stub_bin / "curl").symlink_to(ROOT / "Tests/Scripts/peer-curl-stub.py")
        self.env.update(PATH=str(stub_bin) + ":/usr/bin:/bin", PEER_CURL_STATE=str(self.curl_state),
                        SWARMHUB_GATEWAY="http://127.0.0.1:1")
        os.environ.update(self.env)
        self.sync()
        # Cross-review finding 4: coding jobs are owner-gated by default. These suites exercise the owner's explicit
        # automatic Codex route; claude orders stay owner-gated regardless (sim/test_fixes6_policy.py).
        peer.control.publish({"coding_gate": "auto"})

    def stop_background(self):
        # ready precedes code-job's final wake-start/logging. Let launchers exit
        # before stopping recovery so no late child can recreate the temp HOME.
        for pidfile in (self.home / ".hermes/swarmhub/job-completions").glob("job.*/pid"):
            pid = int(pidfile.read_text())
            deadline = time.monotonic() + 3
            while peer.control.process_alive(pid) and time.monotonic() < deadline:
                time.sleep(.01)
            if peer.control.process_alive(pid):
                peer.control.terminate(pid)
        # The supervisor goes first so it cannot restart the worker being stopped.
        for name in ("job-wake.supervisor.pid", "job-wake.pid"):
            pidfile = self.home / ".hermes/swarmhub" / name
            if not pidfile.exists():
                continue
            pid = int(pidfile.read_text())
            if peer.control.process_alive(pid):
                peer.control.terminate(pid)
                deadline = time.monotonic() + 3
                while peer.control.process_alive(pid) and time.monotonic() < deadline:
                    time.sleep(.01)

        # A supervisor spawned by the test's last subprocess may start after the pid files were read;
        # it reveals itself only by its HOME. Stop every such child before the temp HOME goes.
        for _ in range(2):
            for pid in children_by_home(self.home):
                if peer.control.process_alive(pid):
                    peer.control.terminate(pid)
            time.sleep(.2)

    def sync(self):
        (self.curl_state / "config").write_text(json.dumps({
            "keys": self.keys, "reply": self.reply, "status": self.status,
            "terminal": self.terminal, "failed": self.failed}))

    @property
    def requests(self):
        path = self.curl_state / "requests"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def msg(self, *args):
        self.sync()
        return subprocess.run(["/bin/sh", str(MSG), "--from", "sender", "--to", "recipient", *args],
                              env=self.env, capture_output=True, text=True, timeout=12)

    def turns(self):
        return [r for r in self.requests if r[0].endswith("/chat/stream")]

    def eventually(self, check, timeout=30):
        # swift test runs ten pattern interpreters alongside the native suites. On a loaded Mac,
        # the real code-job subprocess chain can exceed eight seconds even with synthetic CLI I/O.
        # Keep polling the same condition; a monotonic deadline still fails a hung worker.
        deadline = time.monotonic() + timeout
        while not check():
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, f"condition not met within {timeout}s")
            time.sleep(min(.02, remaining))

    def completion(self, origin="sender", name="job.synthetic"):
        job = peer.state() / "job-completions" / name
        job.mkdir(parents=True)
        for field, value in {"bot": "worker", "origin": origin, "agent": "codex", "exit": "0",
                             "status": "ok", "directory": "/tmp/synthetic", "ready": ""}.items():
            (job / field).write_text(value)
        return job

    def retry(self, job):
        self.sync()
        (job / "next-attempt").unlink(missing_ok=True)
        # A separate interpreter proves delivery does not depend on in-memory job state.
        return subprocess.run(["/usr/bin/python3", str(RUNTIME), "retry-once"], env=self.env,
                              capture_output=True, text=True, timeout=12)

    def test_default_held_send_makes_no_http_request_and_survives_process_exit(self):
        result = self.msg("--no-wait", "--", "FYI only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("held:"))
        self.assertEqual(self.requests, [])
        context = peer.before_turn("recipient", "app-session", "next-turn")["context"]
        self.assertIn("FYI only", context)
        self.assertIn("Message from sender", context)
        self.assertEqual((peer.state() / "peer-inbox.sqlite").stat().st_mode & 0o777, 0o600)
        peer.after_turn("recipient", "app-session", "next-turn", "NO_REPLY")
        self.assertIsNone(peer.before_turn("recipient", "app-session", "later"))

    def test_priority_starts_immediately_and_only_exact_acknowledgements_are_suppressed(self):
        for answer in ["NO_REPLY", " \nno_reply\t", "[silent]"]:
            with self.subTest(answer=answer):
                self.reply = answer
                (self.curl_state / "requests").unlink(missing_ok=True)
                result = self.msg("--priority", "--no-wait", "--", "action")
                self.assertEqual(result.returncode, 0, result.stderr)
                log = peer.state() / "bot-messages.log"
                self.eventually(lambda: log.exists() and "suppressed" in log.read_text())
                self.assertEqual(len(self.turns()), 1)
                log.unlink()
        self.reply = "NO_REPLY is the marker; here is the useful answer."
        result = self.msg("--priority", "--no-wait", "--", "question")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.eventually(lambda: len(self.turns()) == 3)  # previous turn plus ask and reverse reply
        self.assertIn(self.reply, self.turns()[-1][1]["input"])

    def test_late_acknowledgement_after_wait_timeout_does_not_wake_sender(self):
        self.release.unlink()
        result = self.msg("--priority", "--wait", "1", "--", "slow request")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.release.touch()
        log = peer.state() / "bot-messages.log"
        self.eventually(lambda: "suppressed" in log.read_text())
        self.assertEqual(len(self.turns()), 1)

    def test_inbox_is_scoped_fifo_and_claimed_by_one_concurrent_turn(self):
        peer.hold("sender", "recipient", "first")
        peer.hold("worker", "recipient", "second")
        self.assertIsNone(peer.before_turn("coordinator", "s", "t"))
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda s: peer.before_turn("recipient", s, "t"), ["a", "b"]))
        self.assertEqual(sum(r is not None for r in results), 1)
        context = next(r for r in results if r)["context"]
        self.assertLess(context.index("first"), context.index("second"))

    def test_unanswered_turn_recovers_and_wrong_profile_cannot_acknowledge(self):
        peer.hold("sender", "recipient", "recover")
        peer.before_turn("recipient", "a", "t1")
        peer.after_turn("recipient", "a", "t1", "")
        peer.after_turn("coordinator", "a", "t1", "answer")
        self.assertIsNone(peer.before_turn("recipient", "b", "t2"))
        self.assertIn("recover", peer.before_turn("recipient", "a", "t2")["context"])
        with peer.database() as db:
            db.execute("UPDATE inbox SET expires=0")
        self.assertIn("recover", peer.before_turn("recipient", "b", "t3")["context"])

    def test_job_wakes_ordering_bot_not_coordinator_and_is_not_sent_twice(self):
        job = self.completion()
        os.environ["SWARMHUB_COORDINATOR"] = "coordinator"
        self.env["SWARMHUB_COORDINATOR"] = "coordinator"
        self.assertEqual(self.retry(job).returncode, 0)
        self.assertTrue((job / "delivered").exists())
        self.assertIn("/p/sender/", self.turns()[0][0])
        self.assertIn(job.name, self.turns()[0][1]["input"])
        self.retry(job)
        self.assertEqual(len(self.turns()), 1)
        self.assertNotIn("synthetic-sender", json.dumps(self.turns()[0][1]))

    def test_unknown_origin_falls_back_to_configured_coordinator(self):
        job = self.completion("unknown")
        (peer.state() / "coding.conf").write_text("SLOTS=2\nCOORDINATOR=coordinator\n")
        self.retry(job)
        self.assertTrue((job / "delivered").exists())
        self.assertIn("/p/coordinator/", self.turns()[0][0])

    def test_missing_coordinator_retains_job_until_configured(self):
        job = self.completion("")
        self.retry(job)
        self.assertFalse((job / "delivered").exists())
        self.assertEqual(self.turns(), [])
        (peer.state() / "coding.conf").write_text("COORDINATOR=coordinator\n")
        self.retry(job)
        self.assertTrue((job / "delivered").exists())

    def test_offline_failure_retries_from_disk_and_reads_rotated_key(self):
        job = self.completion()
        self.status = 503
        self.retry(job)
        self.assertFalse((job / "delivered").exists())
        self.assertTrue((job / "last-error").exists())
        self.status = 200
        self.keys["sender"] = "synthetic-rotated"
        (self.home / ".hermes/profiles/sender/.env").write_text("API_SERVER_KEY=synthetic-rotated\n")
        self.retry(job)
        self.assertTrue((job / "delivered").exists())
        self.assertEqual((job / "attempts").read_text(), "2")
        self.assertEqual(self.turns()[-1][2], "Bearer synthetic-rotated")

    def test_failed_or_truncated_stream_is_not_a_delivered_job(self):
        job = self.completion()
        self.failed = True
        self.retry(job)
        self.assertFalse((job / "delivered").exists())
        self.failed, self.terminal = False, False
        self.retry(job)
        self.assertFalse((job / "delivered").exists())
        self.terminal = True
        self.retry(job)
        self.assertTrue((job / "delivered").exists())

    def test_concurrent_workers_observe_one_outbox_claim(self):
        job = self.completion()
        self.release.unlink()
        one = subprocess.Popen(["/usr/bin/python3", str(RUNTIME), "retry-once"], env=self.env)
        self.addCleanup(lambda: one.poll() is None and one.kill())
        self.eventually(lambda: len(self.turns()) == 1)
        self.assertEqual(self.retry(job).returncode, 0)
        self.release.touch()
        self.assertEqual(one.wait(8), 0)
        self.assertEqual(len(self.turns()), 1)

    def test_real_code_job_publishes_private_record_and_triggers_wake(self):
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        codex = bin_dir / "codex"
        codex.write_text("#!/bin/sh\necho synthetic-result\nexit 7\n")
        codex.chmod(0o755)
        env = dict(self.env, PATH=str(bin_dir) + ":" + self.env["PATH"], CODE_JOB_TICK="0.05",
                   HERMES_SESSION_ID="swarmhub-from-sender")
        result = subprocess.run(["/bin/sh", str(JOB), "--bot", "worker",
                                 "--order", "codex", "--model", "synthetic-model", "--report", "report.txt",
                                 "--dir", str(self.home), "--", "private task text"],
                                env=env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 7, result.stderr)
        jobs = list((peer.state() / "job-completions").glob("job.*"))
        self.assertEqual(len(jobs), 1)
        job = jobs[0]
        self.eventually(lambda: (job / "delivered").exists())
        self.assertEqual((job / "exit").read_text().strip(), "7")
        self.assertEqual((job / "status").read_text().strip(), "failed")
        for field in job.iterdir():
            self.assertNotIn("private task text", field.read_text())
            self.assertNotIn("synthetic-result", field.read_text())
            self.assertEqual(field.stat().st_mode & 0o777, 0o600)
        self.assertIn("exit: 7", self.turns()[0][1]["input"])

    def test_shutdown_during_delivery_retains_pending_completion_without_orphans(self):
        job = self.completion()
        self.release.unlink()
        child = subprocess.Popen([sys.executable, str(RUNTIME), "supervise"], env=self.env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.addCleanup(child.stderr.close)
        self.eventually(lambda: len(self.turns()) == 1)
        worker = int((peer.state() / "job-wake.pid").read_text())
        child.send_signal(signal.SIGTERM)
        self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
        self.assertTrue((job / "ready").exists())
        self.assertFalse((job / "delivered").exists())
        self.assertFalse(peer.control.process_alive(worker))
        self.eventually(lambda: children_by_home(self.home) == [])
        self.release.touch()
        self.assertEqual(len(self.turns()), 1)

    def test_shutdown_retains_inflight_and_queued_durable_deliveries_for_retry(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                ids = [peer.control.enqueue("sender", "recipient", f"pending {n}") for n in range(2)]
                self.release.unlink(missing_ok=True)
                turns = len(self.turns())
                child = subprocess.Popen([sys.executable, str(RUNTIME), "supervise"], env=self.env,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                self.addCleanup(lambda child=child: child.poll() is None and child.kill())
                self.addCleanup(child.stderr.close)
                self.eventually(lambda: len(self.turns()) == turns + 1)
                child.send_signal(sig)
                self.assertEqual(child.wait(timeout=5), 0, child.stderr.read().decode())
                self.eventually(lambda: children_by_home(self.home) == [])
                with peer.control.database() as db:
                    rows = [db.execute("SELECT status,attempts FROM deliveries WHERE id=?", (ident,)).fetchone()
                            for ident in ids]
                    self.assertEqual([tuple(row) for row in rows], [("pending", 1), ("pending", 1)])
                    self.assertEqual([db.execute("SELECT status FROM receipts WHERE target='recipient' AND id=?",
                                                 (ident,)).fetchone()[0] for ident in ids], ["pending", "pending"])
                    db.execute("UPDATE deliveries SET due=0")
                self.release.touch()
                peer.control.retry_deliveries()
                with peer.control.database() as db:
                    self.assertEqual([db.execute("SELECT status FROM deliveries WHERE id=?", (ident,)).fetchone()[0]
                                      for ident in ids], ["delivered", "delivered"])
                self.assertEqual(len(self.turns()), turns + 3)

    def test_install_writes_loadable_profile_plugin_without_keys(self):
        peer.install("recipient")
        folder = self.home / ".hermes/profiles/recipient/plugins/swarmhub-peer"
        self.assertIn("version: 1.3.3\n", (folder / "plugin.yaml").read_text())
        namespace = {"__file__": str(folder / "__init__.py")}  # Hermes imports it from its file
        exec((folder / "__init__.py").read_text(), namespace)
        hooks = {}
        class Context:
            def register_hook(self, name, callback):
                hooks[name] = callback
        import types
        constants = types.SimpleNamespace(get_hermes_home=lambda: folder.parents[1])
        registry = types.SimpleNamespace(adopt_local=lambda *a, **kw: types.SimpleNamespace())
        modules = {"hermes_constants": constants, "tools": types.ModuleType("tools"),
                   "tools.process_registry": types.SimpleNamespace(process_registry=registry)}
        with patch.dict("sys.modules", modules), patch.object(subprocess, "Popen") as popen, \
                patch.object(peer.select, "select", return_value=([True], [], [])):
            popen.return_value.stdout.readline.return_value = peer.SUPERVISOR_READY
            namespace["register"](Context())
        peer.hold("sender", "recipient", "app next turn")
        self.assertIn("app next turn", hooks["pre_llm_call"](session_id="app", turn_id="1")["context"])
        hooks["post_llm_call"](session_id="app", turn_id="1", assistant_response="NO_REPLY")
        self.assertIsNone(hooks["pre_llm_call"](session_id="app", turn_id="2"))


if __name__ == "__main__":
    unittest.main()
