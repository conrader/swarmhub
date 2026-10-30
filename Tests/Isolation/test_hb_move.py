"""ops/hb-move against a throwaway root: every system command is a logging stand-in on PATH (getent and useradd keep
a fake passwd), except visudo, which is the real one checking the real sudoers text. The health probes are patched.
Nothing here touches the host's users, systemd, nginx or sudoers.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sim"))
import sim_isolation  # noqa: F401,E402  Exits unless isolated (sim/ISOLATION.md); keep it the first import.
import io  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import socket  # noqa: E402
import tempfile  # noqa: E402
import unittest  # noqa: E402
from contextlib import redirect_stderr, redirect_stdout  # noqa: E402
from unittest import mock  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / "ops"), str(REPO / "ops/isolation")]
import hb_move  # noqa: E402
import hb_render  # noqa: E402
import swarmhub_registry  # noqa: E402

SKILL = REPO / "Resources/Skills/swarmhub-messages/scripts"
STUB = r"""#!/bin/sh
echo "$(basename "$0") $*" >> "$HB_ROOT/commands"
case $(basename "$0") in
  getent) grep "^$2:" "$HB_ROOT/etc/$1" || exit 2 ;;
  groupadd) echo "$2:x:3000:" >> "$HB_ROOT/etc/group" ;;
  useradd)
    for last; do :; done
    n=$(wc -l < "$HB_ROOT/etc/passwd")
    echo "$last:x:$((2100 + n)):$((2100 + n))::/home/$last:/usr/sbin/nologin" >> "$HB_ROOT/etc/passwd"
    mkdir -p "$HB_ROOT/home/$last" ;;
  nginx) [ "$1" = -T ] && cat "$HB_ROOT/nginx-T"; exit "$(cat "$HB_ROOT/nginx-rc" 2>/dev/null || echo 0)" ;;
  visudo) exec /usr/sbin/visudo "$@" 2>&1 ;;
esac
exit 0
"""


def free_ports(n):
    sockets = [socket.socket() for _ in range(n)]
    for s in sockets:
        s.bind(("127.0.0.1", 0))
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return ports


class HbMove(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="hb-move."))
        self.addCleanup(shutil.rmtree, self.root, True)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("getent", "groupadd", "useradd", "usermod", "chown", "systemctl", "nginx", "visudo", "runuser"):
            (bin_dir / name).write_text(STUB)
            (bin_dir / name).chmod(0o755)
        (self.root / "etc").mkdir()
        (self.root / "etc/passwd").write_text("hermes:x:2000:2000::/home/hermes:/bin/bash\n")
        (self.root / "etc/group").write_text("hermes:x:2000:\n")
        (self.root / "nginx-T").write_text(f"server {{\n    {hb_render.INCLUDE}\n    location /p/ {{}}\n}}\n")
        profile = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        shutil.copytree(SKILL, profile / "skills/swarmhub/swarmhub-messages/scripts")
        (profile / ".env").write_text("API_SERVER_KEY=sk-profile-key-1234\n")
        (profile / "memories").mkdir()
        (profile / "memories/MEMORY.md").write_text("remember this\n")
        self.ports = dict(zip(swarmhub_registry.PORTS, free_ports(3)))
        env = dict(os.environ, PATH=f"{bin_dir}:/usr/bin:/bin", HB_ROOT=str(self.root))
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.health = mock.patch.object(hb_move.Box, "answers", return_value=True)
        self.answers = self.health.start()
        self.addCleanup(self.health.stop)

    def hb(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = hb_move.main(["--root", str(self.root), *map(str, argv)])
        return rc, out.getvalue(), err.getvalue()

    def move(self, *extra):
        ports = [f"--{k.replace('_', '-')}={v}" for k, v in self.ports.items()]
        return self.hb("grok-swarmhub", *ports, "--shared-unit", "hermes-gateway.service", *extra)

    def commands(self):
        path = self.root / "commands"
        return path.read_text().splitlines() if path.exists() else []

    def test_move_builds_the_account_gateway_registry_and_routes(self):
        rc, out, err = self.move()
        self.assertEqual(rc, 0, err + out)
        home = self.root / "home/hb-swarmhub"
        moved = home / ".hermes/profiles/grok-swarmhub"
        self.assertEqual((moved / "memories/MEMORY.md").read_text(), "remember this\n")
        self.assertFalse((self.root / "home/hermes/.hermes/profiles/grok-swarmhub").exists())
        backup = self.root / "home/.swarmhub-hb-move/grok-swarmhub.1"
        self.assertEqual(backup.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual((backup / ".env").read_text(), "API_SERVER_KEY=sk-profile-key-1234\n")
        for folder in (home, home / ".hermes", home / ".hermes/profiles", home / ".ssh"):
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700, folder)
        self.assertEqual((home / ".hermes/.env").stat().st_mode & 0o777, 0o600)
        default_env = (home / ".hermes/.env").read_text()
        self.assertIn(f"API_SERVER_PORT={self.ports['gateway_port']}", default_env)
        self.assertNotIn("sk-profile-key-1234", default_env)
        reg = swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")  # trusted: root-owned in the namespace
        self.assertEqual(reg["bots"]["grok-swarmhub"], dict(user="hb-swarmhub", uid=2101, **self.ports))
        self.assertEqual((self.root / "etc/swarmhub/bots.json").stat().st_mode & 0o777, 0o644)
        unit = (self.root / "etc/systemd/system/hermes-bot@.service").read_text()
        self.assertIn("User=hb-%i", unit)
        self.assertIn("ExecStart=/opt/hermes-core/current/bin/hermes gateway run", unit)
        dropin = self.root / "etc/systemd/system/hermes-bot@swarmhub.service.d/10-ports.conf"
        self.assertIn(f"API_SERVER_PORT={self.ports['gateway_port']}", dropin.read_text())
        snippet = (self.root / "etc/nginx/snippets/swarmhub-bots.conf").read_text()
        self.assertIn(f"location ^~ /p/grok-swarmhub/ {{\n        proxy_pass http://127.0.0.1:{self.ports['gateway_port']};",
                      snippet)
        self.assertIn(f"location ^~ /swarmhub/webhook/grok-swarmhub/ {{\n        limit_except POST", snippet)
        self.assertIn(f"proxy_pass http://127.0.0.1:{self.ports['receiver_port']};", snippet)
        self.assertEqual(snippet.count(f"proxy_pass http://127.0.0.1:{self.ports['control_port']};"), 2)
        sudoers = self.root / "etc/sudoers.d/swarmhub-peer-bridge"
        self.assertEqual(sudoers.stat().st_mode & 0o777, 0o440)
        self.assertIn("!use_pty", sudoers.read_text())
        self.assertFalse((self.root / "etc/sudoers.d/.swarmhub-peer-bridge.tmp").exists())
        lib = self.root / "usr/local/lib/swarmhub"
        self.assertEqual({p.name: p.stat().st_mode & 0o777 for p in lib.iterdir()},
                         {"peer-bridge": 0o755, "peer_bridge.py": 0o644, "swarmhub_registry.py": 0o644})
        commands = self.commands()
        for expected in ("groupadd --system swarmhub-peer", "usermod -aG swarmhub-peer hermes",
                         "usermod -aG swarmhub-peer hb-swarmhub", f"chown -R hb-swarmhub:hb-swarmhub {home}",
                         f"chown -R root:root {lib}", "systemctl daemon-reload",
                         "systemctl enable --now hermes-bot@swarmhub.service", "nginx -t", "systemctl reload nginx"):
            self.assertIn(expected, commands)
        self.assertTrue(any(c.startswith("useradd --system --user-group --create-home --home-dir /home/hb-swarmhub")
                            for c in commands))
        receiver = [c for c in commands if c.startswith("runuser -u hb-swarmhub -- ")]
        self.assertEqual(len(receiver), 1)
        self.assertIn(f"webhook receiver install --port {self.ports['receiver_port']}", receiver[0])
        self.assertTrue(any(c.startswith("visudo -cf ") for c in commands))
        self.assertLess(commands.index("systemctl enable --now hermes-bot@swarmhub.service"), commands.index("nginx -t"))
        journal = json.loads((self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json").read_text())
        self.assertEqual(journal["steps"][-1], "verified")
        self.assertNotIn("sk-", out + err + json.dumps(journal) + "\n".join(commands))

    def test_undo_brings_the_bot_and_its_new_state_back(self):
        self.assertEqual(self.move()[0], 0)
        moved = self.root / "home/hb-swarmhub/.hermes/profiles/grok-swarmhub"
        (moved / "memories/MEMORY.md").write_text("learned while dedicated\n")
        rc, out, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 0, err + out)
        restored = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        self.assertEqual((restored / "memories/MEMORY.md").read_text(), "learned while dedicated\n")
        self.assertFalse(moved.exists())
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.1.dedicated").is_dir())
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.1").is_dir())
        self.assertEqual(swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")["bots"], {})
        self.assertNotIn("grok-swarmhub", (self.root / "etc/nginx/snippets/swarmhub-bots.conf").read_text())
        self.assertFalse((self.root / "etc/sudoers.d/swarmhub-peer-bridge").exists())
        self.assertFalse((self.root / "etc/systemd/system/hermes-bot@swarmhub.service.d").exists())
        commands = self.commands()
        for expected in ("systemctl disable --now hermes-bot@swarmhub.service", f"chown -R hermes:hermes {restored.with_name('.grok-swarmhub.hb-undo')}",
                         "systemctl restart hermes-gateway.service"):
            self.assertIn(expected, commands)
        self.assertTrue(any("webhook receiver uninstall" in c for c in commands))
        self.assertFalse(any(c.startswith("userdel") for c in commands))  # the account stays; removing it is manual
        self.assertIn("userdel -r hb-swarmhub", out)
        self.assertFalse((self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json").exists())
        rc, _, err = self.move()  # and it can be moved again: backups are numbered
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.2").is_dir())

    def test_the_shared_gateway_is_stopped_only_around_copy_and_retire(self):
        self.assertEqual(self.move()[0], 0)
        commands = self.commands()
        stop, start = commands.index("systemctl stop hermes-gateway.service"), commands.index(
            "systemctl start hermes-gateway.service")
        self.assertLess(stop, start)
        self.assertLess(start, commands.index("systemctl enable --now hermes-bot@swarmhub.service"))
        steps = json.loads((self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json").read_text())["steps"]
        self.assertLess(steps.index("shared-stopped"), steps.index("copying"))
        self.assertLess(steps.index("retired"), steps.index("shared-started"))
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as exited:  # --shared-unit is required, never guessed
            hb_move.main(["--root", str(self.root), "grok-other",
                          *[f"--{k.replace('_', '-')}={v}" for k, v in self.ports.items()]])
        self.assertEqual(exited.exception.code, 2)
        self.assertIn("--shared-unit", err.getvalue())

    def test_a_failed_copy_restarts_the_shared_gateway_and_undo_sets_the_copy_aside(self):
        real = hb_move.Box.run

        def run(box, argv):
            if argv[0] == "cp":
                Path(argv[3]).mkdir(parents=True)
                (Path(argv[3]) / "half").write_text("partial")
                raise hb_move.Failed("cp exited 1: disk full")
            return real(box, argv)
        with mock.patch.object(hb_move.Box, "run", run):
            rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("disk full", err)
        self.assertIn("systemctl start hermes-gateway.service", self.commands())
        original = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        self.assertTrue((original / ".env").is_file())
        before = len(self.commands())
        rc, _, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 0, err)
        self.assertTrue((original / ".env").is_file())
        # Undo restarts the shared unit whenever the move had stopped it (a hard crash skips the move's finally).
        self.assertIn("systemctl restart hermes-gateway.service", self.commands()[before:])
        partial = self.root / "home/.swarmhub-hb-move/grok-swarmhub.1.partial"
        self.assertEqual((partial / "half").read_text(), "partial")
        self.assertFalse((self.root / "home/hb-swarmhub/.hermes/profiles/grok-swarmhub").exists())
        self.assertEqual(self.move()[0], 0)  # and the move can run again

    def test_a_crash_right_after_the_retire_is_undone_from_the_copy(self):
        real = hb_move.Journal.done

        def done(journal, step, **fields):
            if step == "retired":
                raise OSError("power cut")
            return real(journal, step, **fields)
        with mock.patch.object(hb_move.Journal, "done", done):
            rc, _, err = self.move()
        self.assertEqual(rc, 1)
        original = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        self.assertFalse(original.exists())
        self.assertIn("systemctl start hermes-gateway.service", self.commands())
        stale = original.with_name(".grok-swarmhub.hb-undo")  # left by an earlier undo that crashed mid-copy
        stale.mkdir()
        (stale / "torn").write_text("x")
        rc, _, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 0, err)
        self.assertEqual((original / "memories/MEMORY.md").read_text(), "remember this\n")
        self.assertFalse((original / "torn").exists())
        self.assertFalse(stale.exists())
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.1").is_dir())
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.1.dedicated").is_dir())

    def test_undo_without_the_shared_account_fails_cleanly(self):
        self.assertEqual(self.move()[0], 0)
        (self.root / "etc/passwd").write_text("".join(line + "\n" for line in
                                              (self.root / "etc/passwd").read_text().splitlines()
                                              if not line.startswith("hermes:")))
        rc, _, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 1)
        self.assertIn("no shared account hermes", err)
        self.assertIn(".swarmhub-hb-move/grok-swarmhub.1", err)

    def test_dry_run_changes_nothing(self):
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))
        rc, out, err = self.move("--dry-run")
        self.assertEqual(rc, 0, err)
        self.assertIn("+ useradd", out)
        self.assertIn("+ systemctl enable --now hermes-bot@swarmhub.service", out)
        after = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*") if p.name != "commands")
        self.assertEqual(after, before)
        self.assertEqual([c for c in self.commands() if not c.startswith(("getent", "nginx -T"))], [])

    def test_preflight_refusals_change_nothing(self):
        cases = []
        cases.append(("no include", lambda: (self.root / "nginx-T").write_text("server {}\n"), "include"))
        cases.append(("missing profile", lambda: shutil.rmtree(self.root / "home/hermes/.hermes/profiles/grok-swarmhub"),
                      "no profile"))
        cases.append(("no skill", lambda: shutil.rmtree(
            self.root / "home/hermes/.hermes/profiles/grok-swarmhub/skills"), "swarmhub-messages skill"))
        for label, breakage, message in cases:
            with self.subTest(label):
                self.doCleanups()
                self.setUp()
                breakage()
                rc, _, err = self.move()
                self.assertEqual(rc, 1)
                self.assertIn(message, err)
                self.assertEqual([c for c in self.commands() if not c.startswith(("getent", "nginx -T"))], [])
                self.assertFalse((self.root / "etc/swarmhub/bots.json").exists())

    def test_port_and_name_refusals(self):
        self.ports["control_port"] = self.ports["gateway_port"]
        rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("already used", err)
        self.ports = dict(zip(swarmhub_registry.PORTS, free_ports(3)))
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", self.ports["receiver_port"]))
            rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("already in use", err)
        rc, _, err = self.move("--user", "Bad User")
        self.assertEqual(rc, 1)
        self.assertIn("--user must be", err)
        self.assertEqual(self.move()[0], 0)
        rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("already moved", err)

    def test_a_red_gateway_stops_before_routing_and_undo_cleans_up(self):
        self.answers.return_value = False
        rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("does not answer", err)
        self.assertNotIn("nginx -t", self.commands())
        self.assertFalse((self.root / "etc/nginx/snippets/swarmhub-bots.conf").exists())
        journal = json.loads((self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json").read_text())
        self.assertEqual(journal["steps"][-1], "unit")
        rc, out, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.root / "home/hermes/.hermes/profiles/grok-swarmhub/.env").is_file())
        self.assertEqual(swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")["bots"], {})

    def test_failing_nginx_check_restores_the_previous_snippet(self):
        self.assertEqual(self.move()[0], 0)
        snippet = self.root / "etc/nginx/snippets/swarmhub-bots.conf"
        before = snippet.read_text()
        (self.root / "nginx-rc").write_text("1")
        rc, _, err = self.hb("--render-nginx")
        self.assertEqual(rc, 1)
        self.assertEqual(snippet.read_text(), before)

    def old_plugin(self):
        """A peer plugin as 1.4.14 installed it: absolute paths into the shared account."""
        profile = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        script = profile / "skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py"
        folder = profile / "plugins/swarmhub-peer"
        folder.mkdir(parents=True)
        (folder / "plugin.yaml").write_text("name: swarmhub-peer\nversion: 1.3.3\n")
        (folder / "__init__.py").write_text(f"import runpy, sys\nsys.path.insert(0, {str(script.parent)!r})\n"
                                            f"register = runpy.run_path({str(script)!r})[\"register\"]\n")
        return script

    def loads(self, profile):
        """The peer-runtime.py the profile's plugin loads, as Hermes would import it from there (runpy stubbed)."""
        seen = []
        plugin = profile / "plugins/swarmhub-peer/__init__.py"
        with mock.patch("runpy.run_path", lambda path: seen.append(path) or {"register": None}), \
                mock.patch.object(sys, "path", list(sys.path)):
            exec(plugin.read_text(), {"__file__": str(plugin)})
        return Path(seen[0])

    def test_the_moved_profile_loads_its_own_peer_plugin(self):
        old = self.old_plugin()
        self.assertEqual(self.move()[0], 0)
        self.assertFalse(old.exists())  # retired: the old absolute loader would find nothing
        moved = self.root / "home/hb-swarmhub/.hermes/profiles/grok-swarmhub"
        script = moved / "skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py"
        self.assertEqual(self.loads(moved), script)
        self.assertTrue(script.is_file())
        self.assertEqual((moved / "plugins/swarmhub-peer/__init__.py").read_text(),
                         hb_render.plugin_loader("skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py"))
        self.assertIn(f"chown -R hb-swarmhub:hb-swarmhub {self.root / 'home/hb-swarmhub'}", self.commands())
        # A 1.4.14 skill reinstalling the plugin in the bot account names that account's home; undo rewrites it.
        (moved / "plugins/swarmhub-peer/__init__.py").write_text(
            f"import runpy\nregister = runpy.run_path({str(script)!r})[\"register\"]\n")
        self.assertEqual(self.hb("--undo", "grok-swarmhub")[0], 0)
        restored = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        self.assertEqual(self.loads(restored), old)  # back in the shared account, the restored copy loads there
        self.assertTrue(old.is_file())

    def test_a_profile_without_the_plugin_gets_none(self):
        self.assertEqual(self.move()[0], 0)
        self.assertFalse((self.root / "home/hb-swarmhub/.hermes/profiles/grok-swarmhub/plugins").exists())

    def test_an_undo_that_fails_after_the_restore_runs_again_to_the_end(self):
        for failing in ("systemctl restart hermes-gateway.service", "nginx -t"):
            with self.subTest(failing):
                self.doCleanups()
                self.setUp()
                self.assertEqual(self.move()[0], 0)
                real, calls = hb_move.Box.run, []

                def run(box, argv):
                    if " ".join(map(str, argv)) == failing and not calls:
                        calls.append(argv)
                        raise hb_move.Failed(f"{argv[0]} exited 1: down")
                    return real(box, argv)
                with mock.patch.object(hb_move.Box, "run", run):
                    rc, _, err = self.hb("--undo", "grok-swarmhub")
                self.assertEqual(rc, 1)
                restored = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
                self.assertTrue((restored / ".env").is_file())
                journal = self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json"
                self.assertIn("restored", json.loads(journal.read_text())["undone"])
                before = len(self.commands())
                rc, out, err = self.hb("--undo", "grok-swarmhub")
                self.assertEqual(rc, 0, err + out)
                again = self.commands()[before:]
                self.assertNotIn("systemctl disable --now hermes-bot@swarmhub.service", again)
                self.assertFalse(any("receiver uninstall" in c or c.startswith("chown") for c in again), again)
                if failing.startswith("systemctl"):
                    self.assertIn(failing, again)
                else:
                    self.assertNotIn("systemctl restart hermes-gateway.service", again)
                self.assertIn("nginx -t", again)
                self.assertEqual((restored / "memories/MEMORY.md").read_text(), "remember this\n")
                backups = sorted(p.name for p in (self.root / "home/.swarmhub-hb-move").iterdir())
                self.assertEqual(backups, ["grok-swarmhub.1", "grok-swarmhub.1.dedicated"])
                self.assertEqual(swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")["bots"], {})
                self.assertNotIn("grok-swarmhub", (self.root / "etc/nginx/snippets/swarmhub-bots.conf").read_text())
                self.assertFalse((self.root / "etc/sudoers.d/swarmhub-peer-bridge").exists())
                self.assertFalse(journal.exists())

    def test_a_crash_right_after_the_undo_rename_resumes_from_the_inode(self):
        self.assertEqual(self.move()[0], 0)
        with mock.patch.object(hb_move, "set_aside", side_effect=OSError("power cut")):
            self.assertEqual(self.hb("--undo", "grok-swarmhub")[0], 1)
        self.assertTrue((self.root / "home/hermes/.hermes/profiles/grok-swarmhub/.env").is_file())
        moved = self.root / "home/hb-swarmhub/.hermes/profiles/grok-swarmhub"
        self.assertTrue(moved.is_dir())  # the rename landed; the dedicated copy is not set aside yet
        rc, out, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 0, err + out)
        self.assertFalse(moved.exists())
        self.assertTrue((self.root / "home/.swarmhub-hb-move/grok-swarmhub.1.dedicated").is_dir())
        self.assertFalse((self.root / "home/.swarmhub-hb-move/grok-swarmhub.2.dedicated").exists())

    def test_a_retry_after_a_partial_undo_rechecks_the_restored_profile(self):
        def gone(path):
            shutil.rmtree(path)

        def replaced(path):  # same content, another folder
            os.rename(path, self.root / "elsewhere")
            shutil.copytree(self.root / "elsewhere", path, symlinks=True)

        def token_gone(path):
            (path / getattr(hb_move, "RESTORE_MARK", ".swarmhub-hb-undo")).unlink(missing_ok=True)
        for change, refusal in ((gone, "is gone again"), (replaced, "exists again"), (token_gone, "exists again")):
            with self.subTest(change.__name__):
                self.doCleanups()
                self.setUp()
                self.assertEqual(self.move()[0], 0)
                real = hb_move.Box.run

                def run(box, argv):
                    if " ".join(map(str, argv)) == "systemctl restart hermes-gateway.service":
                        raise hb_move.Failed("systemctl exited 1: down")
                    return real(box, argv)
                with mock.patch.object(hb_move.Box, "run", run):
                    self.assertEqual(self.hb("--undo", "grok-swarmhub")[0], 1)
                journal = self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json"
                self.assertIn("restored", json.loads(journal.read_text())["undone"])
                change(self.root / "home/hermes/.hermes/profiles/grok-swarmhub")
                before = len(self.commands())
                rc, out, err = self.hb("--undo", "grok-swarmhub")
                self.assertEqual(rc, 1, err + out)
                self.assertIn(refusal, err)
                again = [c for c in self.commands()[before:] if not c.startswith("getent ")]
                self.assertEqual(again, [])  # no restart of the shared gateway, no cleanup
                self.assertTrue(journal.exists())
                self.assertIn("grok-swarmhub", swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")["bots"])
                self.assertTrue((self.root / "etc/sudoers.d/swarmhub-peer-bridge").exists())

    def test_a_finished_undo_leaves_no_restore_token(self):
        self.assertEqual(self.move()[0], 0)
        self.assertEqual(self.hb("--undo", "grok-swarmhub")[0], 0)
        restored = self.root / "home/hermes/.hermes/profiles/grok-swarmhub"
        self.assertTrue((restored / ".env").is_file())
        self.assertEqual(list(restored.glob(".swarmhub-hb-*")), [])

    def test_undo_still_refuses_a_profile_that_reappeared(self):
        self.assertEqual(self.move()[0], 0)
        (self.root / "home/hermes/.hermes/profiles/grok-swarmhub").mkdir()
        rc, _, err = self.hb("--undo", "grok-swarmhub")
        self.assertEqual(rc, 1)
        self.assertIn("exists again", err)
        self.assertNotIn("systemctl disable --now hermes-bot@swarmhub.service", self.commands())

    def test_bad_sudoers_never_lands(self):
        broken = self.root / "broken-ops"
        shutil.copytree(REPO / "ops", broken)
        (broken / "isolation/sudoers-swarmhub-peer-bridge").write_text("this is not sudoers\n")
        with mock.patch.object(hb_move, "HERE", broken):
            rc, _, err = self.move()
        self.assertEqual(rc, 1)
        self.assertIn("visudo exited", err)
        self.assertFalse((self.root / "etc/sudoers.d/swarmhub-peer-bridge").exists())
        self.assertFalse((self.root / "etc/sudoers.d/.swarmhub-peer-bridge.tmp").exists())


if __name__ == "__main__":
    unittest.main()
