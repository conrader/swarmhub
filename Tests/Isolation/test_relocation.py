"""The peer plugin's loader survives a profile moving between accounts, and a durable message keeps its tier.

swarm_control.plugin_loader (the skill) and hb_render.plugin_loader (ops/hb-move) must write the same text; the loader
names the skill relative to the plugin, so it works wherever the profile lives. The deliveries table gains `tier` on
an existing box database, and enqueue refuses an unknown tier.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sim"))
import sim_isolation  # noqa: F401,E402  Exits unless isolated (sim/ISOLATION.md); keep it the first import.
import os  # noqa: E402
import shutil  # noqa: E402
import sqlite3  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import unittest  # noqa: E402
from unittest import mock  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SKILL = REPO / "Resources/Skills/swarmhub-messages/scripts"
RELATIVE = "skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py"
sys.path[:0] = [str(REPO / "ops"), str(SKILL)]
import hb_render  # noqa: E402
import swarm_control  # noqa: E402
import swarm_delivery  # noqa: E402
import swarm_store  # noqa: E402


def loaded_script(loader, plugin_file):
    """The peer-runtime.py path the loader hands to runpy when Hermes imports it from `plugin_file`."""
    seen = []
    with mock.patch("runpy.run_path", lambda path: seen.append(path) or {"register": "hook"}), \
            mock.patch.object(sys, "path", list(sys.path)):
        namespace = {"__file__": str(plugin_file)}
        exec(loader, namespace)
    assert namespace["register"] == "hook"
    return Path(seen[0])


class Loader(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="relocation."))
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_skill_and_hb_move_write_the_same_relative_loader(self):
        home = self.root / "home/hermes/.hermes/profiles/p"
        self.assertEqual(swarm_control.plugin_loader(home / RELATIVE, home), hb_render.plugin_loader(RELATIVE))
        self.assertNotIn(str(self.root), hb_render.plugin_loader(RELATIVE))

    def test_the_loader_follows_the_profile(self):
        loader = hb_render.plugin_loader(RELATIVE)
        for home in (self.root / "home/hermes/.hermes/profiles/p", self.root / "home/hb-p/.hermes/profiles/p",
                     self.root / "home/hb-p/.hermes"):
            with self.subTest(str(home)):
                self.assertEqual(loaded_script(loader, home / "plugins/swarmhub-peer/__init__.py"), home / RELATIVE)

    def test_a_skill_outside_the_home_stays_absolute(self):
        home, script = self.root / "home/hermes/.hermes/profiles/p", self.root / "checkout/peer-runtime.py"
        loader = swarm_control.plugin_loader(script, home)
        self.assertEqual(loaded_script(loader, home / "plugins/swarmhub-peer/__init__.py"), script)

    def test_install_writes_the_relative_loader_for_its_own_skill(self):
        home = self.root / "home"
        scripts = home / ".hermes/profiles/p/skills/swarmhub/swarmhub-messages/scripts"
        shutil.copytree(SKILL, scripts)
        code = ("import sys, runpy; sys.argv = ['peer-runtime.py', 'install', 'p']\n"
                "import swarm_control as c; c.register = lambda p: None; c.receiver.ensure = lambda: None\n"
                f"runpy.run_path({str(scripts / 'peer-runtime.py')!r}, run_name='__main__')\n")
        env = dict(os.environ, HOME=str(home), PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run([sys.executable, "-B", "-c", code], cwd=str(scripts), env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        plugin = home / ".hermes/profiles/p/plugins/swarmhub-peer/__init__.py"
        self.assertEqual(plugin.read_text(), hb_render.plugin_loader(RELATIVE))


class DurableTier(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="relocation-home."))
        self.addCleanup(shutil.rmtree, self.home, True)
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        (self.home / ".hermes/profiles/b").mkdir(parents=True)

    def test_an_existing_deliveries_table_gains_tier(self):
        folder = self.home / ".hermes/swarmhub"
        folder.mkdir(parents=True)
        with sqlite3.connect(folder / "control.sqlite") as db:  # the 1.4.14 schema
            db.execute("CREATE TABLE deliveries(id TEXT PRIMARY KEY, sender TEXT, target TEXT, text TEXT, task TEXT,"
                       " status TEXT, attempts INTEGER DEFAULT 0, due REAL DEFAULT 0, error TEXT)")
            db.execute("INSERT INTO deliveries(id,sender,target,text,task,status) VALUES('old','a','b','t','',"
                       "'pending')")
        ident = swarm_delivery.enqueue("s1", "b", "from the shared account", bridged=True, tier="shared")
        with swarm_store.database() as db:
            rows = dict(db.execute("SELECT id, tier FROM deliveries").fetchall())
        self.assertEqual(rows, {"old": None, ident: "shared"})
        with mock.patch.object(swarm_delivery, "deliver", return_value=0) as deliver:
            swarm_delivery.retry_deliveries()
        tiers = {call.args[3]: call.args[5] for call in deliver.call_args_list}
        self.assertEqual(tiers, {"old": "", ident: "shared"})

    def test_a_dedicated_tier_is_stored_unmarked_and_an_unknown_one_refused(self):
        ident = swarm_delivery.enqueue("a", "b", "from a bot account", bridged=True, tier="dedicated")
        with swarm_store.database() as db:
            self.assertEqual(db.execute("SELECT tier FROM deliveries WHERE id=?", (ident,)).fetchone()[0], "")
        with self.assertRaises(ValueError):
            swarm_delivery.enqueue("a", "b", "spoofed", bridged=True, tier="root")

    def test_the_shared_tier_reaches_bot_msg(self):
        with mock.patch.object(swarm_delivery, "receipt_claim", return_value="token"), \
                mock.patch.object(swarm_delivery.lifecycle, "call", return_value=0) as call:
            swarm_delivery.deliver("s1", "b", "hi", "delivery.x", tier="shared")
            swarm_delivery.deliver("a", "b", "hi", "delivery.y")
        shared, plain = (c.args[0] for c in call.call_args_list)
        self.assertIn("--shared", shared)
        self.assertNotIn("--shared", plain)


if __name__ == "__main__":
    unittest.main()
