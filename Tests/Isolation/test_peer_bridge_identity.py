"""Who may send as whom (swapdesign3 addendum (a), test L8) and swapdesign2 §2's isolation tests.

The sender is (account from SUDO_UID, profile from --from-profile). Dedicated accounts send only as their own slug;
the shared account only as one of its own profiles, recorded tier=shared. Refusals exit 77 with nothing sent.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sim"))
import sim_isolation  # noqa: F401,E402  Exits unless isolated (sim/ISOLATION.md); keep it the first import.
import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import threading  # noqa: E402
import unittest  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from world import KEYS, OPS, SKILL_PATH, STUBS, World  # noqa: E402


class SharedSenders(unittest.TestCase):
    """L8 (addendum): shared profiles s1 and s2 of `hermes`, each with its own gateway and key, and bot a."""

    def setUp(self):
        self.w = World()
        self.addCleanup(lambda: self.w.close())

    def late(self, stub, sender):
        return [c for c in self.w.chats(stub) if c["input"].startswith(f"[Reply from {sender} via SwarmHub]")]

    def test_s1_and_s2_to_a_late_replies_are_not_crossed(self):
        w = self.w
        w.mode("a", "delay:3")
        results = {}

        def send(profile):
            results[profile] = w.bot_msg(profile, "--to", "a", "--priority", "--wait", "1", "--", f"hi from {profile}")
        threads = [threading.Thread(target=send, args=(p,)) for p in ("s1", "s2")]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(60)
        for profile in ("s1", "s2"):
            self.assertEqual(results[profile].returncode, 124, results[profile].stderr)
        sessions = {c["session"]: c for c in w.chats("a")}
        self.assertEqual(set(sessions), {"swarmhub-from-s1", "swarmhub-from-s2"})
        for profile in ("s1", "s2"):
            chat = sessions[f"swarmhub-from-{profile}"]
            self.assertEqual(chat["input"], f"[Message from {profile} via SwarmHub (shared)]\nhi from {profile}")
            self.assertEqual(chat["key"], "a")
        self.assertTrue(w.until(lambda: len(w.bridge_log("hb-a")) == 2, timeout=12))
        self.assertEqual(sorted(line.split("\t")[2:4] for line in w.bridge_log("hb-a")),
                         [["s1", "tier=shared"], ["s2", "tier=shared"]])
        for profile, other in (("s1", "s2"), ("s2", "s1")):
            late = w.until(lambda: self.late(profile, "a"), timeout=12)
            self.assertEqual([(c["key"], c["session"]) for c in late], [(profile, "swarmhub-from-a")], w.requests(profile))
            self.assertFalse(any(f"key={other}" in line for line in w.requests(profile)))
        self.assertEqual(w.requests("shared"), [])
        self.assertEqual(w.files_containing(w.home("hb-a"), KEYS["s1"]) + w.files_containing(w.home("hermes"), KEYS["a"]),
                         [])

    def test_a_to_s1_late_reply_lands_in_a(self):
        w = self.w
        w.mode("shared", "delay:3")
        r = w.bot_msg("a", "--to", "s1", "--priority", "--wait", "1", "--", "for the shared bot")
        self.assertEqual(r.returncode, 124, r.stderr)
        (chat,) = w.chats("shared")
        self.assertEqual((chat["profile"], chat["key"], chat["session"]), ("s1", "s1", "swarmhub-from-a"))
        self.assertEqual(chat["input"], "[Message from a via SwarmHub]\nfor the shared bot")
        late = w.until(lambda: self.late("a", "s1"), timeout=12)
        self.assertEqual([(c["key"], c["session"]) for c in late], [("a", "swarmhub-from-s1")])
        self.assertEqual(w.chats("s1") + w.chats("s2"), [])

    def refused(self, account, argv, sudo_user=None):
        r = self.w.bridge_call(account, argv, sudo_user=sudo_user)
        self.assertEqual(r.returncode, 77, (r.stdout, r.stderr))
        self.assertNotIn(b"bridge: http=", r.stderr)
        return r.stderr.decode()

    def test_refusals_exit_77_and_send_nothing(self):
        w = self.w
        self.assertIn("own account", self.refused("hermes", ["stream", "b", "--from-profile", "a"]))
        self.assertIn("no profile ghost", self.refused("hermes", ["stream", "b", "--from-profile", "ghost"]))
        self.assertIn("sends as a, not s1", self.refused("hb-a", ["stream", "b", "--from-profile", "s1"]))
        self.assertIn("uid 2009", self.refused("hb-x", ["stream", "b", "--from-profile", "a"], sudo_user="hb-a"))
        for verb in ("held", "durable"):
            self.refused("hb-a", [verb, "b", "--from-profile", "b"])
        for stub in STUBS:
            self.assertEqual(w.requests(stub), [], stub)
        self.assertFalse((w.root / "drops.log").exists())
        self.assertEqual(w.query("hb-b", "peer-inbox.sqlite", "SELECT * FROM inbox"), [])

    def test_planted_symlinks_answer_nothing_about_other_homes(self):
        # Root follows no link the shared account planted: a link to a real folder in hb-a's 0700 home is refused
        # exactly like a missing one, so the answer reveals nothing about that home.
        w = self.w
        profiles = w.home("hermes") / ".hermes/profiles"
        (profiles / "probe").symlink_to(w.profile("a") / "skills")
        self.assertIn("no profile probe", self.refused("hermes", ["stream", "b", "--from-profile", "probe"]))
        r = w.bridge_call("hb-a", ["stream", "probe", "--from-profile", "a"])
        self.assertEqual(r.returncode, 2, r.stderr)
        hermes = w.home("hermes") / ".hermes"
        hermes.rename(w.home("hermes") / ".hermes-real")
        hermes.symlink_to(w.home("hermes") / ".hermes-real")  # an intermediate link: s1 is real, its path is not
        self.assertIn("no profile s1", self.refused("hermes", ["stream", "b", "--from-profile", "s1"]))
        for stub in STUBS:
            self.assertEqual(w.requests(stub), [], stub)

    def test_bad_requests(self):
        w = self.w
        cases = [(["stream", "a", "--from-profile", "a"], 64, "own account"),
                 (["stream", "ghost", "--from-profile", "a"], 2, "no bot named ghost"),
                 (["stream", "b"], 64, "profile names"),
                 (["stream", "b", "--from-profile", "a", "--max-time", "0"], 64, "--max-time"),
                 (["stream", "b", "--from-profile", "a", "--max-time", "1801"], 64, "--max-time"),
                 (["held", "b", "--from-profile", "a", "--max-time", "5"], 64, "stream only"),
                 (["send", "b", "--from-profile", "a"], 64, "usage"),
                 (["stream", "../b", "--from-profile", "a"], 64, "profile names")]
        for argv, code, text in cases:
            with self.subTest(argv=argv):
                r = w.bridge_call("hb-a", argv)
                self.assertEqual(r.returncode, code, r.stderr)
                self.assertIn(text, r.stderr.decode())
        for data in (b"", b"5\nabc", b"x\nabc", b"0\n", b"99999999\nabc"):
            with self.subTest(stdin=data):
                self.assertEqual(w.bridge_call("hb-a", ["held", "b", "--from-profile", "a"], stdin=data).returncode, 64)
        r = w.bridge_call("hb-a", ["stream", "b", "--from-profile", "a"], text=b"x")
        self.assertEqual(r.returncode, 0)  # the drop happened only for the accepted request, into b's account
        self.assertEqual([line.split()[1] for line in (w.root / "drops.log").read_text().splitlines()], ["hb-b"])

    def test_registry_must_exist_and_be_root_only(self):
        w = self.w
        w.registry.chmod(0o666)
        self.assertIn("writable only by root", self.refused("hb-a", ["stream", "b", "--from-profile", "a"]))
        w.registry.unlink()
        self.assertIn("no registry", self.refused("hb-a", ["stream", "b", "--from-profile", "a"]))
        r = w.bot_msg("a", "--to", "b", "--priority", "--", "anyone?")
        self.assertEqual(r.returncode, 2, r.stderr)  # without a registry bot-msg knows no b: refused, nothing sent
        self.assertIn("no bot named b", r.stderr)
        for stub in STUBS:
            self.assertEqual(w.requests(stub), [], stub)


class ThreeModes(unittest.TestCase):
    """swapdesign2 §2: A→B arrives with sender A in all three modes; a forged --from is recorded as the real sender."""

    def setUp(self):
        self.w = World()
        self.addCleanup(lambda: self.w.close())

    def rendered(self, account, profile):
        script = self.w.profile(profile) / SKILL_PATH / "peer-runtime.py"
        code = ("import runpy, json, sys; m = runpy.run_path(sys.argv[1]); "
                "print(json.dumps(m['before_turn'](sys.argv[2], 'sess', 'turn')))")
        env = dict(self.w.env(account), PYTHONPATH=str(script.parent))
        r = subprocess.run([sys.executable, "-B", "-c", code, str(script), profile], env=env, capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)["context"]

    def test_held(self):
        w = self.w
        r = w.bot_msg("a", "--from", "c", "--to", "b", "--", "an fyi")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith("held:"), r.stdout)
        self.assertEqual(w.query("hb-b", "peer-inbox.sqlite", "SELECT sender,recipient,text,tier FROM inbox"),
                         [("a", "b", "an fyi", "")])
        self.assertIn("[Message from a via SwarmHub]\n[Held message id=", self.rendered("hb-b", "b"))
        self.assertEqual(w.query("hb-a", "peer-inbox.sqlite", "SELECT * FROM inbox"), [])
        r = w.bot_msg("s1", "--to", "b", "--", "shared fyi")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(("s1", "shared"), w.query("hb-b", "peer-inbox.sqlite", "SELECT sender,tier FROM inbox"))
        self.assertIn("[Message from s1 via SwarmHub (shared)]\n[Held message id=", self.rendered("hb-b", "b"))
        for stub in STUBS:
            self.assertEqual(w.requests(stub), [], stub)

    def test_durable(self):
        w = self.w
        r = w.bot_msg("a", "--from", "c", "--to", "b", "--durable", "--", "must arrive")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.startswith("pending:"), r.stdout)
        self.assertEqual(w.query("hb-b", "control.sqlite", "SELECT sender,target,text FROM deliveries"),
                         [("a", "b", "must arrive")])
        self.assertEqual(w.query("hb-a", "control.sqlite", "SELECT * FROM deliveries"), [])
        # B's own recovery worker delivers it locally, with B's key, as from a.
        chats = w.until(lambda: w.chats("b"), timeout=20)
        self.assertTrue(chats and chats[0]["input"].startswith("[Message from a via SwarmHub]\n"), chats)
        self.assertEqual(chats[0]["key"], "b")
        # From the shared account the delivered message carries the same (shared) marker as a held one.
        r = w.bot_msg("s1", "--to", "b", "--durable", "--", "shared and durable")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(("s1", "shared"), w.query("hb-b", "control.sqlite", "SELECT sender,tier FROM deliveries"))
        chats = w.until(lambda: [c for c in w.chats("b") if "shared and durable" in c["input"]], timeout=20)
        self.assertTrue(chats and chats[0]["input"].startswith("[Message from s1 via SwarmHub (shared)]\n"), chats)

    def test_priority(self):
        w = self.w
        r = w.bot_msg("a", "--from", "c", "--to", "b", "--priority", "--", "now please")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "Hi from b")
        self.assertEqual([c["session"] for c in w.chats("b")], ["swarmhub-from-a"])

    def test_default_from_a_dedicated_account_is_the_shared_default(self):
        # A registered account's own ~/.hermes is only its gateway's stub default; "default" is the box's default bot.
        w = self.w
        r = w.bot_msg("a", "--to", "default", "--priority", "--", "for the main bot")
        self.assertEqual(r.returncode, 0, r.stderr)
        (chat,) = w.chats("shared")
        self.assertEqual((chat["profile"], chat["key"], chat["session"]), ("default", "hermes-default", "swarmhub-from-a"))
        self.assertEqual(w.query("hb-a", "peer-inbox.sqlite", "SELECT * FROM inbox"), [])
        self.assertEqual(w.chats("a"), [])

    def test_text_never_reaches_sudo_argv(self):
        w = self.w
        argv_log = w.root / "sudo-argv"
        shim = w.root / "argv-sudo"
        shim.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {argv_log}\nexec {Path(__file__).with_name("fake-sudo")} "$@"\n')
        shim.chmod(0o755)
        for mode in ("--held", "--durable", "--priority"):
            r = w.bot_msg("a", "--to", "b", mode, "--", f"secret words {mode}", SWARMHUB_SUDO=shim)
            self.assertEqual(r.returncode, 0, r.stderr)
        logged = argv_log.read_text()
        self.assertEqual(len(logged.splitlines()), 3)
        self.assertNotIn("secret words", logged)


class Units(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(OPS))
        import peer_bridge
        import swarmhub_registry
        self.bridge, self.registry = peer_bridge, swarmhub_registry

    def test_drop_privileges_order_and_no_way_back(self):
        calls = []
        state = {"uid": 0, "gid": 0}

        class FakeOS:
            def initgroups(self, name, gid):
                calls.append(("initgroups", name, gid))

            def setgid(self, gid):
                calls.append(("setgid", gid))
                state["gid"] = gid

            def setuid(self, uid):
                if state["uid"] != 0:
                    raise PermissionError
                calls.append(("setuid", uid))
                state["uid"] = uid

            def getuid(self):
                return state["uid"]
            geteuid = getuid

            def getgid(self):
                return state["gid"]
            getegid = getgid

        account = self.bridge.Account("hb-b", 2002, 2002, "/home/hb-b")
        real = self.bridge.os
        self.bridge.os = FakeOS()
        try:
            self.bridge.drop_privileges(account)
            self.assertEqual(calls, [("initgroups", "hb-b", 2002), ("setgid", 2002), ("setuid", 2002)])
            state.update(uid=0, gid=0)
            FakeOS.setuid = lambda self, uid: state.update(uid=uid)  # a kernel that lets root back in
            with self.assertRaises(self.bridge.Stop):
                self.bridge.drop_privileges(account)
        finally:
            self.bridge.os = real

    def test_env_value_matches_bot_msg(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", delete=False) as handle:
            handle.write('API_SERVER_KEY=old\nexport API_SERVER_KEY="sk-new"\r\nOTHER=1\n')
        self.addCleanup(os.unlink, handle.name)
        self.assertEqual(self.bridge.env_value(handle.name, "API_SERVER_KEY"), "sk-new")
        self.assertEqual(self.bridge.env_value(handle.name, "MISSING"), "")

    def test_registry_validation(self):
        good = {"version": 1, "bots": {"a": {"user": "hb-a", "uid": 2001, "gateway_port": 8651,
                                             "receiver_port": 8751, "control_port": 8761}}}
        reg = self.registry.validate(good)
        self.assertEqual(reg["shared"], {"user": "hermes", "gateway_port": 8642})
        self.assertEqual(self.registry.by_uid(reg, 2001), "a")
        self.assertIsNone(self.registry.by_uid(reg, 2002))
        bad = [{"version": 2, "bots": {}},
               {"version": 1, "bots": {"default": good["bots"]["a"]}},
               {"version": 1, "bots": {"a": dict(good["bots"]["a"], uid=0)}},
               {"version": 1, "bots": {"a": dict(good["bots"]["a"], extra=1)}},
               {"version": 1, "bots": {"a": dict(good["bots"]["a"], gateway_port=8642)}},
               {"version": 1, "bots": {"a": dict(good["bots"]["a"], user="hermes")}},
               {"version": 1, "bots": {"a": good["bots"]["a"], "b": dict(good["bots"]["a"], user="hb-b")}},
               {"version": 1, "bots": {"a": dict(good["bots"]["a"], control_port=80)}},
               {"version": 1, "bots": {"a/b": good["bots"]["a"]}}]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(self.registry.RegistryError):
                self.registry.validate(data)

    def test_registry_save_is_atomic_and_world_readable(self):
        import tempfile
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: [p.unlink() for p in folder.iterdir()] and folder.rmdir())
        path = folder / "bots.json"
        with self.registry.locked(path) as reg:
            reg["bots"]["a"] = {"user": "hb-a", "uid": 2001, "gateway_port": 8651, "receiver_port": 8751,
                                "control_port": 8761}
            self.registry.save(path, reg)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.registry.load(path, trusted=False)["bots"]["a"]["uid"], 2001)
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["bots.json", "bots.json.lock"])

    def test_launcher_refuses_an_unsafe_install(self):
        import shutil
        import tempfile
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder)
        for name in ("peer-bridge", "peer_bridge.py", "swarmhub_registry.py"):
            shutil.copy2(OPS / name, folder / name)
        folder.chmod(0o777)
        r = subprocess.run([sys.executable, "-IB", str(folder / "peer-bridge"), "stream", "b", "--from-profile", "a"],
                           capture_output=True, text=True, input="1\nx", env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(r.returncode, 77)
        self.assertIn("must be root-owned", r.stderr)
        folder.chmod(0o755)
        r = subprocess.run([sys.executable, "-IB", str(folder / "peer-bridge"), "stream", "b", "--from-profile", "a"],
                           capture_output=True, text=True, input="1\nx", env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(r.returncode, 77, r.stderr)  # no registry at /etc/swarmhub here, or no sudo caller


if __name__ == "__main__":
    unittest.main()
