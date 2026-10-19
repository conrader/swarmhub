"""Gap closures after live pass 4: the evidence gate and its wake wording (P01/P04), managed webhook routines (P02),
the provisioning hook and secret intake (P06), and the live harness's real-CLI detection. Synthetic CLI/curl only."""
import json
import io
import os
from pathlib import Path
import stat
import socket
import subprocess
import threading
import unittest
import urllib.error
import urllib.request

import test_peer_runtime as boundary
import test_patterns as patterns

peer = boundary.peer
control = peer.control
SWARMCTL = boundary.RUNTIME.with_name("swarmctl")


class GapTests(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    sync = boundary.PeerTests.sync
    requests = boundary.PeerTests.requests
    turns = boundary.PeerTests.turns
    eventually = boundary.PeerTests.eventually
    stop_background = boundary.PeerTests.stop_background
    cli = patterns.ObservedPatternTests.cli
    spec = patterns.ObservedPatternTests.spec
    submit = patterns.ObservedPatternTests.submit
    job = patterns.ObservedPatternTests.job
    code_job = patterns.ObservedPatternTests.code_job
    decide = patterns.ObservedPatternTests.decide

    def ctl(self, *args, payload=None, text=None):
        return subprocess.run(["/usr/bin/python3", str(SWARMCTL), *args], env=self.env, capture_output=True, text=True,
                              input=json.dumps(payload) if payload is not None else text, timeout=12)

    def newest_job(self):
        return max((peer.state() / "job-completions").glob("job.*"), key=lambda p: p.stat().st_mtime)

    def field(self, job, name):
        return (job / name).read_text().strip()

    def wake_for(self, ident):
        self.eventually(lambda: (self.job(ident) / "delivered").exists())
        return next(t[1]["input"] for t in self.turns() if self.job(ident).name in t[1]["input"])

    # P01/P04: done needs evidence code-job gathered itself; the wake separates verified from unverified.
    def test_P01_P04_done_requires_evidence_and_wake_states_verified_versus_unverified(self):
        self.cli()
        for env in (self.env, os.environ):
            env.pop("CODE_JOB_VERIFY", None)
        result = self.code_job()
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("code-job: unverified: fresh report but no new commit and no passing verification", result.stderr)
        job = self.newest_job()
        self.assertEqual([self.field(job, k) for k in ("status", "evidence", "tests-passed", "commit-evidence", "report-valid", "cli-exit")],
                         ["unverified", "none", "not-run", "not-a-repo", "true", "0"])
        self.assertEqual(self.code_job("--verify", "true").returncode, 0)
        self.assertEqual(self.field(self.newest_job(), "evidence"), "tests")
        self.assertEqual(self.code_job("--verify", "exit 4").returncode, 66)
        self.assertEqual([self.field(self.newest_job(), k) for k in ("verify-exit", "tests-passed", "verify-command")], ["4", "false", "exit 4"])

        verified = self.submit("verified-work", verify="true")
        control.tick()
        self.eventually(lambda: (self.job(verified) / "ready").exists())
        control.tick()
        self.assertEqual(control.action(verified)["status"], "done")
        message = self.wake_for(verified)
        self.assertIn("status: ok", message)
        self.assertIn("Verified by code-job: fresh report at the recorded path; verification command exit 0 (true).", message)
        self.assertIn("Unverified: commit (directory is not a git repository); correctness of the report and of the work itself.", message)
        self.assertNotIn("verified work by", message, "report text never enters the wake")

        unverified = self.submit("unverified-work")
        control.tick()
        self.eventually(lambda: (self.job(unverified) / "ready").exists())
        control.tick()
        self.assertEqual(control.action(unverified)["status"], "failed", "no evidence holds the bot's queue")
        message = self.wake_for(unverified)
        self.assertIn("status: unverified", message)
        self.assertIn("Verified by code-job: fresh report at the recorded path.", message)
        self.assertIn("Unverified: commit (directory is not a git repository); tests (no verification command configured); "
                      "correctness of the report and of the work itself.", message)
        # The approved verification command is part of the record: a different one is refused at launch.
        with self.assertRaises(ValueError):
            control.check_job(verified, "worker", str(self.home), "synthetic-model", "high", "verified-work.txt",
                              "verified-work", "codex", "/bin/false")
        with self.assertRaises(ValueError):
            self.submit("multi-line", verify="true\nrm -rf /")

    def test_P01_P04_a_new_commit_in_the_directory_is_evidence(self):
        repo = self.home / "repo"
        repo.mkdir()
        git = dict(self.env, PATH="/usr/bin:/bin")
        for argv in (["git", "init", "-q"], ["git", "commit", "-q", "--allow-empty", "-m", "base"]):
            subprocess.run(argv, cwd=repo, env=git, check=True, capture_output=True)
        before = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, env=git, capture_output=True, text=True).stdout.strip()
        folder = self.home / "cli"
        folder.mkdir(exist_ok=True)
        (folder / "codex").write_text('#!/bin/sh\nset -e\nprintf work > "$SWARMHUB_REPORT_FILE"\necho changed > work.txt\n'
                                      'git add -A && git commit -qm done\necho result\nexit 0\n')
        (folder / "codex").chmod(0o755)
        env = dict(self.env, PATH=str(folder) + ":" + self.env["PATH"], CODE_JOB_TICK="0.05")  # keeps the curl stub
        env.pop("CODE_JOB_VERIFY", None)
        result = subprocess.run(["/bin/sh", str(boundary.JOB), "--bot", "worker", "--origin", "sender", "--order", "codex", "--dir", str(repo),
                                 "--model", "synthetic-model", "--report", "REPORT.txt", "--", "commit something"],
                                env=env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        job = self.newest_job()
        after = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, env=git, capture_output=True, text=True).stdout.strip()
        self.assertEqual([self.field(job, k) for k in ("evidence", "commit-evidence", "head-before", "head-after", "tests-passed")],
                         ["commit", "true", before, after, "not-run"])
        self.assertNotEqual(before, after)
        self.eventually(lambda: (job / "delivered").exists())
        message = next(t[1]["input"] for t in self.turns() if job.name in t[1]["input"])
        self.assertIn(f"Verified by code-job: fresh report at the recorded path; new commit {after[:12]} (HEAD was {before[:12]}).", message)
        self.assertIn("Unverified: tests (no verification command configured); correctness", message)

    # P02: a managed webhook routine with an owner-only key that no command prints.
    def test_P02_webhook_routine_register_show_rotate_fire_never_prints_the_key(self):
        registered = self.ctl("webhook", "register", "recipient", "nightly")
        self.assertEqual(registered.returncode, 0, registered.stderr)
        record = json.loads(registered.stdout)
        key_file = Path(record["key_file"])
        key = key_file.read_text().strip()
        self.assertGreaterEqual(len(key), 32)
        self.assertEqual(stat.S_IMODE(key_file.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(key_file.parent.stat().st_mode), 0o700)
        self.assertNotIn(key, registered.stdout + registered.stderr)
        self.assertEqual(record["key"], "stored in key_file (owner-only); never printed")
        self.assertIn("/swarmhub/webhook/recipient/nightly/", record["url"])
        slug = record["url"].rsplit("/", 1)[1]
        with control.database() as db:
            rows = [dict(r) for r in db.execute("SELECT * FROM webhooks")]
        self.assertEqual(len(rows), 1)
        self.assertNotIn(key, json.dumps(rows))
        again = json.loads(self.ctl("webhook", "register", "recipient", "nightly").stdout)
        self.assertEqual((again["url"], key_file.read_text().strip()), (record["url"], key), "re-registering neither rotates nor reveals")
        shown = json.loads(self.ctl("webhook", "show", "recipient", "nightly").stdout)
        self.assertEqual(shown["url"], record["url"])
        self.assertNotIn(key, json.dumps(shown))
        self.assertNotIn(key, self.ctl("webhook", "list").stdout)
        self.assertNotIn(key, self.ctl("status").stdout)
        with self.assertRaises(ValueError):
            control.webhook.register("nobody", "nightly")

        rejected = self.ctl("webhook", "fire", "recipient", "nightly", slug, payload={"key": "wrong", "text": "run"})
        self.assertEqual(rejected.returncode, 77, rejected.stderr)
        self.assertEqual(self.ctl("webhook", "fire", "recipient", "nightly", "other-slug", payload={"key": key, "text": "run"}).returncode, 77)
        fired = json.loads(self.ctl("webhook", "fire", "recipient", "nightly", slug, payload={"key": key, "text": "run the nightly"}).stdout)
        self.assertTrue(fired["delivery"].startswith("delivery."))
        with control.database() as db:
            row = dict(db.execute("SELECT * FROM deliveries WHERE id=?", (fired["delivery"],)).fetchone())
        self.assertEqual((row["sender"], row["target"]), ("recipient", "recipient"))
        self.assertTrue(row["text"].startswith("[Webhook routine nightly for recipient]\nrun the nightly"))
        self.eventually(lambda: any("Webhook routine nightly" in t[1]["input"] for t in self.turns()))
        self.assertIn("/p/recipient/", next(t[0] for t in self.turns() if "Webhook routine nightly" in t[1]["input"]))

        rotated = json.loads(self.ctl("webhook", "rotate", "recipient", "nightly").stdout)
        new_key = key_file.read_text().strip()
        self.assertNotEqual(new_key, key)
        self.assertEqual(stat.S_IMODE(key_file.stat().st_mode), 0o600)
        self.assertGreater(rotated["rotated"], record["rotated"])
        self.assertEqual(rotated["url"], record["url"], "rotation keeps the URL")
        with self.assertRaises(PermissionError):
            control.webhook.fire("recipient", "nightly", slug, key, "stale key")
        self.assertEqual(control.webhook.fire("recipient", "nightly", slug, new_key, "fresh key")["status"], "pending")

    def test_P02_loopback_http_receiver(self):
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
        except PermissionError:
            self.skipTest("sandbox forbids loopback sockets; HTTP handler covered without sockets")
        record = control.webhook.register("recipient", "nightly")
        key = Path(record["key_file"]).read_text().strip()
        control.webhook.rotate("recipient", "nightly")
        new_key = Path(record["key_file"]).read_text().strip()
        slug = record["url"].rsplit("/", 1)[1]
        # The loopback receiver: the key travels in a header, the answer never echoes it.
        ports = []
        for expected, headers, path in ((202, {"X-SwarmHub-Key": new_key}, record["url"].split("8745", 1)[1]),
                                        (403, {"X-SwarmHub-Key": key}, record["url"].split("8745", 1)[1]),
                                        (404, {"X-SwarmHub-Key": new_key}, "/swarmhub/webhook/recipient/other/" + slug)):
            ready = threading.Event()
            thread = threading.Thread(target=control.webhook.serve,
                                      kwargs={"port": 0, "once": True, "ready": lambda p: (ports.append(p), ready.set())}, daemon=True)
            thread.start()
            self.assertTrue(ready.wait(5))
            request = urllib.request.Request(f"http://127.0.0.1:{ports[-1]}{path}", data=json.dumps({"text": "via http"}).encode(),
                                             headers={**headers, "Content-Type": "application/json"}, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    status, body = response.status, response.read().decode()
            except urllib.error.HTTPError as error:
                status, body = error.code, error.read().decode()
            thread.join(5)
            self.assertEqual(status, expected, body)
            self.assertNotIn(new_key, body)
            self.assertNotIn(key, body)

    def test_P02_http_handler_rejects_malformed_requests_without_sockets(self):
        record = control.webhook.register("recipient", "nightly")
        key = Path(record["key_file"]).read_text().strip()
        path = record["url"].split("8745", 1)[1]

        class Connection:
            def __init__(self, raw):
                self.raw, self.output = raw, b""

            def makefile(self, *args):
                return io.BytesIO(self.raw)

            def sendall(self, data):
                self.output += data

        for payload, length, presented, expected in ((b'{"text":"run"}', None, key, 202),
                (b'{"text":"run"}', None, "wrong", 403), (b'[]', None, key, 400),
                (b'null', None, key, 400), (b'{', None, key, 400),
                (b'{}', "-1", key, 400), (b'{}', "invalid", key, 400), (b'{}', "999999", key, 400)):
            raw = (f"POST {path} HTTP/1.0\r\nContent-Length: {length or len(payload)}\r\n"
                   f"X-SwarmHub-Key: {presented}\r\n\r\n").encode() + payload
            connection = Connection(raw)
            control.webhook.request_handler()(connection, ("127.0.0.1", 0), None)
            self.assertEqual(int(connection.output.split()[1]), expected)
            self.assertNotIn(key.encode(), connection.output)
        self.assertEqual(self.ctl("webhook", "fire", "recipient", "nightly", "slug", payload=[]).returncode, 64)

    def test_private_files_replace_links_and_webhook_names_do_not_collide(self):
        target = self.home / "public-file"
        target.write_text("unchanged")
        folder = control.intake.folder()
        (folder / "key").symlink_to(target)
        control.intake.intake("key", io.BytesIO(b"synthetic-private"))
        self.assertEqual(target.read_text(), "unchanged")
        self.assertFalse((folder / "key").is_symlink())
        self.assertEqual(stat.S_IMODE((folder / "key").stat().st_mode), 0o600)
        (folder / "link").symlink_to(folder / "key")
        self.assertFalse(control.intake.is_intake_path(str(folder / "link")))
        self.assertFalse(control.intake.is_intake_path(str(folder / "missing")))
        self.assertTrue(control.intake.is_intake_path(str(folder / "key")))
        with self.assertRaises(ValueError):
            control.intake.intake("too-big", io.BytesIO(b"x" * 65536 + b"\nextra"))
        # Before slug-based filenames these two pairs overwrote the same key.
        (self.home / ".hermes/profiles/recipient.a").mkdir()
        (self.home / ".hermes/profiles/recipient.a/.env").write_text("API_SERVER_KEY=synthetic\n")
        one = control.webhook.register("recipient", "a.b")
        two = control.webhook.register("recipient.a", "b")
        self.assertNotEqual(one["key_file"], two["key_file"])
        before = Path(one["key_file"]).read_bytes()
        control.webhook.rotate("recipient.a", "b")
        self.assertEqual(Path(one["key_file"]).read_bytes(), before)

    # P06: a provisioning hook the owner configures and approves; secrets enter by intake file, never by value.
    def test_P06_provisioner_hook_is_owner_gated_and_secret_intake_returns_only_a_path(self):
        control.publish({"owner": "sender", "coordinator": "coordinator"})
        taken = self.ctl("secret", "intake", "model-key", text="sk-synthetic-user-key\n")
        self.assertEqual(taken.returncode, 0, taken.stderr)
        record = json.loads(taken.stdout)
        path = Path(record["path"])
        self.assertEqual(path, peer.state() / "secrets/model-key")
        self.assertEqual(path.read_text(), "sk-synthetic-user-key")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        self.assertNotIn("sk-synthetic", taken.stdout + taken.stderr)
        self.assertEqual(record["value"], "never printed")
        self.assertEqual(self.ctl("secret", "intake", "empty", text="\n").returncode, 64)
        self.assertEqual(self.ctl("secret", "intake", "../escape", text="x").returncode, 64)
        listed = self.ctl("secret", "list")
        self.assertIn("model-key", listed.stdout)
        self.assertNotIn("sk-synthetic", listed.stdout)

        with self.assertRaises(ValueError):
            control.submit({"bot": "worker", "intent": "provision QA", "kind": "provision", "request": {"name": "qa"}})
        provisioner = self.home / "provisioner"
        provisioner.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$HOME/provisioner.args"\n')
        provisioner.chmod(0o755)
        with self.assertRaises(ValueError):
            control.publish({"provisioner": ["provisioner"]})
        control.publish({"provisioner": [str(provisioner), "--qa"]})
        with self.assertRaises(ValueError):
            control.submit({"bot": "worker", "intent": "provision QA", "kind": "provision",
                            "request": {"name": "qa", "model_key": "sk-synthetic-user-key"}})
        ident = control.submit({"bot": "worker", "intent": "provision QA", "kind": "provision",
                                "request": {"name": "qa", "model_key": str(path)}})
        row = control.action(ident)
        self.assertEqual(row["status"], "awaiting-owner")
        self.assertEqual(json.loads(row["spec"])["argv"], [str(provisioner), "--qa", "--request", json.dumps({"model_key": str(path), "name": "qa"}, separators=(",", ":"))])
        self.assertNotIn("sk-synthetic", json.dumps(row))
        control.tick()
        self.assertFalse((self.home / "provisioner.args").exists())
        with self.assertRaises(ValueError):
            self.decide(ident, "coordinator", True)
        self.decide(ident, "sender", True)
        control.tick()
        self.eventually((self.home / "provisioner.args").exists)
        self.eventually(lambda: control.action(ident)["status"] == "done")
        args = (self.home / "provisioner.args").read_text()
        self.assertIn(str(path), args)
        self.assertNotIn("sk-synthetic", args)
        self.assertEqual(self.ctl("secret", "remove", "model-key").returncode, 0)
        self.assertFalse(path.exists())

    # P07: a draft card's Send becomes a managed outbound record; without a configured sender only FAKE is admitted.
    def test_P07_outbound_without_argv_uses_the_configured_sender_or_stays_fake(self):
        control.publish({"coordinator": "coordinator"})
        with self.assertRaises(ValueError):
            control.submit({"bot": "worker", "intent": "draft-1", "kind": "outbound", "to": "someone", "text": "hello"})
        fake = control.submit({"bot": "worker", "intent": "draft-1", "kind": "outbound", "to": "someone", "text": "hello", "fake": True})
        self.assertEqual(json.loads(control.action(fake)["spec"])["argv"], ["/bin/true"])
        self.assertEqual(control.action(fake)["status"], "queued", "a FAKE dry run keeps the auto gate (pass 4 P09)")
        control.tick()
        self.assertEqual((control.action(fake)["status"], control.action(fake)["error"]), ("done", "FAKE: no outbound operation executed"))
        control.publish({"outbound": ["/bin/echo"]})
        real = control.submit({"bot": "worker", "intent": "draft-2", "kind": "outbound", "to": "someone", "text": "hello"})
        self.assertEqual(json.loads(control.action(real)["spec"])["argv"], ["/bin/echo", "--to", "someone", "--text", "hello"])
        self.assertEqual(control.action(real)["status"], "awaiting-coordinator")

    # The live harness: a real authenticated CLI is used only when present and logged in; nothing is stubbed in.
    def test_live_harness_detects_a_real_authenticated_codex_only(self):
        import live_managed
        folder = self.home / "detect-bin"
        folder.mkdir()
        codex = folder / "codex"
        codex.write_text('#!/bin/sh\n[ "$1 $2" = "login status" ] && { echo "Logged in using ChatGPT"; exit 0; }\nexit 9\n')
        codex.chmod(0o755)
        found = live_managed.coding_cli({"PATH": str(folder) + ":/usr/bin:/bin"})
        self.assertEqual((found["agent"], found["bin"]), ("codex", str(folder)))
        self.assertTrue(found["codex_home"].endswith(".codex") or os.environ.get("CODEX_HOME"))
        env = live_managed.cli_env({"HOME": "/qa", "PATH": "/usr/bin:/bin"}, found)
        self.assertEqual((env["PATH"], env["HOME"], env["CODEX_HOME"]), (str(folder) + ":/usr/bin:/bin", "/qa", found["codex_home"]))
        self.assertEqual(live_managed.cli_env({"PATH": "/usr/bin:/bin"}, None), {"PATH": "/usr/bin:/bin"})
        codex.write_text('#!/bin/sh\necho "Not logged in"\nexit 1\n')
        self.assertIsNone(live_managed.coding_cli({"PATH": str(folder) + ":/usr/bin:/bin"}))
        self.assertIsNone(live_managed.coding_cli({"PATH": str(self.home / "nowhere")}))
        repo = live_managed.qa_repo(self.home / "QA-repo")
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True,
                              env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)})
        self.assertEqual(head.returncode, 0, head.stderr)
        self.assertTrue((repo / "README.md").exists())


if __name__ == "__main__":
    unittest.main()
