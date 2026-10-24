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
        return self.hb("grok-swarmhub", *ports, *extra)

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
        backup = self.root / "var/backups/swarmhub-hb-move/grok-swarmhub.1"
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
        self.assertTrue((self.root / "var/backups/swarmhub-hb-move/grok-swarmhub.1.dedicated").is_dir())
        self.assertTrue((self.root / "var/backups/swarmhub-hb-move/grok-swarmhub.1").is_dir())
        self.assertEqual(swarmhub_registry.load(self.root / "etc/swarmhub/bots.json")["bots"], {})
        self.assertNotIn("grok-swarmhub", (self.root / "etc/nginx/snippets/swarmhub-bots.conf").read_text())
        self.assertFalse((self.root / "etc/sudoers.d/swarmhub-peer-bridge").exists())
        self.assertFalse((self.root / "etc/systemd/system/hermes-bot@swarmhub.service.d").exists())
        commands = self.commands()
        for expected in ("systemctl disable --now hermes-bot@swarmhub.service", f"chown -R hermes:hermes {restored}"):
            self.assertIn(expected, commands)
        self.assertTrue(any("webhook receiver uninstall" in c for c in commands))
        self.assertFalse(any(c.startswith("userdel") for c in commands))  # the account stays; removing it is manual
        self.assertIn("userdel -r hb-swarmhub", out)
        self.assertFalse((self.root / "var/lib/swarmhub/hb-move/grok-swarmhub.json").exists())
        rc, _, err = self.move()  # and it can be moved again: backups are numbered
        self.assertEqual(rc, 0, err)
        self.assertTrue((self.root / "var/backups/swarmhub-hb-move/grok-swarmhub.2").is_dir())

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
