"""macsmoke2 regressions for sim/mac-codex-tmp-smoke.sh, stub mode only (no Codex, no provider, no network).

Covers the macsmoke1 review: cleanup with a space in $TMPDIR, a timed-out run whose probe files exist, an
unexpected write on a first run that also timed out, and the non-fallback code-job run in the default command.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sim/mac-codex-tmp-smoke.sh"
SHM = Path("/dev/shm")


def temp_entries():
    return {p.name for p in Path("/tmp").iterdir() if re.match(r"(code-job|macsmoke1)", p.name)}


@unittest.skipIf(os.geteuid() == 0, "the stub denies writes with permission bits, which root ignores")
@unittest.skipUnless(SHM.is_dir() and shutil.which("python3"), "needs /dev/shm for a $TMPDIR outside /tmp")
class SmokeStubTests(unittest.TestCase):
    def setUp(self):
        self.shm = Path(tempfile.mkdtemp(prefix="msk2.", dir=SHM))
        self.home = Path(tempfile.mkdtemp(prefix="msk2-home.", dir=Path.home()))
        self.addCleanup(shutil.rmtree, self.shm, True)
        self.addCleanup(shutil.rmtree, self.home, True)
        self.before = temp_entries()

    def run_smoke(self, tmpdir, *args, log="-"):
        tmpdir.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "SMOKE_TEED")}
        env.update(TMPDIR=str(tmpdir), HOME=str(self.home), SMOKE_LOG=str(log))
        proc = subprocess.run(["sh", str(SCRIPT), "--timeout", "3", *args], cwd=self.shm, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        out = proc.stdout + proc.stderr
        last = [line for line in out.splitlines() if line.startswith("smoke: ")]
        self.assertTrue(last, out[-3000:])
        self.assertEqual(list(tmpdir.iterdir()), [], "disposable dirs left in $TMPDIR")
        self.assertEqual([p.name for p in self.home.iterdir()], [], "outside dir left in HOME")
        self.assertEqual(temp_entries() - self.before, set(), "disposable dirs left in /tmp")
        self.assertIn("cleanup: all disposable directories removed", out)
        self.assertNotIn("REFUSED", out)
        return proc.returncode, last[-1], out

    def test_space_in_tmpdir_cleans_exactly_and_default_run_covers_cj_outside(self):
        decoy = self.shm / "td"  # what an unquoted split of "<shm>/td x/..." would hit
        decoy.mkdir()
        (decoy / "canary").write_text("keep\n")
        rc, last, out = self.run_smoke(self.shm / "td x", "--stub")
        self.assertEqual((decoy / "canary").read_text(), "keep\n")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=PASS "), last)
        self.assertIn("cj-outside", last.split(" enforced=")[1].split(" ")[0])
        self.assertIn("expect fallback=no", out)
        self.assertNotIn("skipped=", last)

    def test_timeout_with_probe_files_present_is_never_pass(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "timeout")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE reason=first-run:timeout "), last)
        self.assertIn("positive control: written; completion marker: written; exit: 124 -> inconclusive (timeout)", out)

    def test_probe_without_completion_marker_is_inconclusive(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "incomplete")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE "), last)
        for run in ("on", "off", "slash", "tmpdir", "cj-home", "cj-sibling", "cj-outside"):
            self.assertIn(f"{run}:probe-incomplete", last)
        self.assertNotIn("enforced=cj", last)

    def test_unexpected_write_on_timed_out_first_run_fails_through_the_log_tee(self):
        log = self.shm / "smoke.log"
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky-timeout", log=log)
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL reason=first-run:timeout "), last)
        self.assertIn("unexpected=on:tmp,on:tmpdir", last)
        self.assertIn(last, log.read_text())

    def test_leaky_full_run_fails(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky")
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL "), last)
        for loc in ("on:tmp", "on:tmpdir", "cj-home:snapshot", "cj-sibling:snapshot"):
            self.assertIn(loc, last)


if __name__ == "__main__":
    unittest.main()
