"""P2b: persisted floors, the protected checkpoint and revoked key IDs from the admin-owned pin file (CORE-PLAN.md
§3.2; CORE-PHASES.md P2b acceptance).

    python3 -m unittest discover -s Tests/Updater
"""

import json
import os
import shutil
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import (CODING, NOW, RELEASE, RELEASE_2, CliCase, box_snapshot, changed,  # noqa: E402
                          index, key_manifest, line, manifest)

LATER = "2026-10-22T00:00:00Z"
SOON = "2026-10-21T00:00:00Z"


class Floors(CliCase):
    def pending_12(self, **kwargs):
        """Bundle 11 fully applied, then 12 staged: its code waits for the confirm."""
        _, comps = self.release("v1")
        self.update("apply", "--staged", str(self.stage(11, comps)))
        self.update("apply")
        _, comps = self.release("v2", version="1.1.0", note="v2")
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, seq=6, **kwargs)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out["detail"])
        return comps

    def refused(self, folder, reason, now=NOW):
        before = box_snapshot(str(self.hermes))
        code, out = self.update("apply", "--staged", str(folder), now=now)
        self.assertEqual((code, out["last"]["verdict"], out["last"]["reason"]), (65, "reject", reason), out["last"])
        self.assertEqual(changed(before, box_snapshot(str(self.hermes))), [])
        return out

    def test_floors_persist_and_refuse_older_content(self):
        comps = self.pending_12()
        self.assertEqual(self.floors(), {"keys_version": 2, "index_seq": 6, "bundle_version": 12})
        _, old = self.release("v1")
        self.refused(self.stage(11, old, seq=7), "bundle_rollback")
        self.refused(self.stage(13, comps, seq=5), "index_rollback")
        self.refused(self.stage(13, comps, seq=7, keys_version=1), "keys_rollback")

    def test_bundle_floor_rises_while_code_waits_and_a_lower_bundle_is_never_offered(self):
        comps = self.pending_12()
        self.assertEqual(self.floors()["bundle_version"], 12)
        _, old = self.release("v1")
        self.refused(self.stage(11, old, seq=7), "bundle_rollback")
        code, out = self.update("apply", "--staged", str(self.stage(12, comps, seq=7)))  # fresher index, same bundle
        self.assertEqual((code, out["last"]["refresh"], out["state"]), (0, True, "pending_confirm"))
        self.assertEqual(self.floors()["index_seq"], 7)
        # Another manifest at 12 (same components, one with an extra requires entry): never accepted.
        other = comps[:-1] + [(dict(comps[-1][0], requires={"updater": ">=1.0"}), comps[-1][1])]
        self.refused(self.stage(12, other, seq=8), "bundle_rollback")

    def test_lowered_state_floor_stops_at_the_checkpoint(self):
        self.pending_12()  # then an operator maintenance pass advances the checkpoint
        self.write_pins(checkpoint={"min_keys_version": 2, "min_index_seq": 6, "min_bundle_version": 12})
        (self.state / "floors.json").write_text(json.dumps({"keys_version": 0, "index_seq": 0, "bundle_version": 0}))
        _, old = self.release("v1")
        self.refused(self.stage(11, old, seq=7), "bundle_rollback")
        self.refused(self.stage(13, old, seq=5), "index_rollback")
        self.wipe_state()  # nothing the bot account writes goes below the checkpoint
        self.refused(self.stage(11, old, seq=7), "bundle_rollback")
        self.write_pins(checkpoint={"min_keys_version": 3})
        self.refused(self.stage(11, old, seq=7, keys_version=2), "keys_rollback")

    def test_effective_floor_is_the_higher_of_checkpoint_and_state(self):
        self.write_pins(checkpoint={"min_bundle_version": 5})
        self.pending_12()
        _, old = self.release("v1")
        self.refused(self.stage(11, old, seq=7), "bundle_rollback")
        status = self.status()
        self.assertEqual(status["floors"]["effective"], {"keys_version": 2, "index_seq": 7, "bundle_version": 12})
        self.assertEqual(status["floors"]["checkpoint"]["bundle_version"], 5)

    def test_revoked_key_is_refused_even_after_the_state_is_wiped(self):
        self.write_pins(revoked=[RELEASE])
        _, comps = self.release("v1")
        out = self.refused(self.stage(11, comps), "key_revoked")
        self.assertEqual(out["pins"]["revoked_key_ids"], [RELEASE])
        self.assertFalse(self.category().exists())
        self.wipe_state()
        self.refused(self.stage(11, comps), "key_revoked")
        code, out = self.update("apply", "--staged", str(self.stage(11, comps, signer=RELEASE_2)))
        self.assertEqual((code, out["state"]), (0, "pending_confirm"))

    def test_a_confirm_covers_only_the_manifest_that_was_confirmed(self):
        comps = self.pending_12()
        self.code_job_slot(self.start_sleeper().pid)
        self.assertEqual(self.update("apply", "--version", "12")[1]["state"], "deferred")  # confirmed, not applied
        (self.state / "floors.json").write_text("{}")  # bot lowers the floors, then offers another signed 12
        other = comps[:-1] + [(dict(comps[-1][0], requires={"updater": ">=1.0"}), comps[-1][1])]
        shutil.rmtree(str(self.hermes / "swarmhub/slots"))
        (self.state / "latest.json").unlink()
        code, out = self.update("apply", "--staged", str(self.stage(12, other, seq=7)))
        self.assertEqual(out["state"], "pending_confirm", out["detail"])
        self.assertEqual(self.live_version(CODING), "1.0.0")

    def test_revocation_stops_a_waiting_confirm(self):
        self.pending_12()
        self.write_pins(revoked=[RELEASE])  # the operator revokes the key that signed bundle 12
        code, out = self.update("apply")
        self.assertEqual((code, out["last"]["reason"]), (65, "key_revoked"))
        self.assertEqual(self.live_version(CODING), "1.0.0")
        self.assertEqual(self.update("check")[1]["last"]["reason"], "key_revoked")

    def test_floors_persist_for_the_stages_that_verified(self):
        self.pending_12()
        folder = self.stage(13, [], seq=7, keys_version=3)
        rogue = index([], 8, signer="TEST-rogue")
        (folder / "channels/stable.json").write_bytes(rogue)
        self.refused(folder, "unknown_key")
        self.assertEqual(self.floors(), {"keys_version": 3, "index_seq": 6, "bundle_version": 12})
        code, out = self.update("apply")  # the stored bundle stays verifiable with the newer key manifest
        self.assertEqual((code, out["state"]), (0, "current"), out["last"])

    def test_expired_index_makes_a_waiting_bundle_stale_until_a_fresh_index(self):
        comps = self.pending_12(expires=SOON)
        code, out = self.update("apply", now=LATER)
        self.assertEqual((code, out["last"]["reason"], out["stale"]), (65, "index_expired", True))
        self.assertEqual(self.live_version(CODING), "1.0.0")
        fresh = self.stage(12, comps, seq=7, omit=("manifest", "blobs"))  # just a fresh index for 12
        code, out = self.update("apply", "--staged", str(fresh), now=LATER)
        self.assertEqual((code, out["last"]["refresh"], out["stale"]), (0, True, False))
        code, out = self.update("apply", "--version", "12", now=LATER)
        self.assertEqual((code, out["state"]), (0, "current"), out["last"])

    def test_stored_bundle_is_reverified_before_use(self):
        comps = self.pending_12()
        stored = self.state / "bundles/12/manifest.json"
        good = stored.read_bytes()
        stored.write_bytes(good + b" ")
        self.assertEqual(self.update("apply")[1]["last"]["reason"], "manifest_hash_mismatch")
        stored.write_bytes(good)
        blob = self.state / "blobs/sha256" / next(c["sha256"] for c, _ in comps if c["name"] == CODING)
        blob.write_bytes(b"altered")
        code, out = self.update("apply")
        self.assertEqual((code, out["last"]["reason"]), (65, "source_unreadable"))
        self.assertEqual(self.live_version(CODING), "1.0.0")

    def test_rollout_percent_is_rechecked_for_a_waiting_bundle(self):
        comps = self.pending_12()
        raw = manifest(12, [c for c, _ in comps])
        halted = self.stage(12, comps, seq=7)
        (halted / "channels/stable.json").write_bytes(index([line(raw, 12, percent=0)], 7))
        self.update("apply", "--staged", str(halted))  # stored index refreshed: the publisher halted 12
        code, out = self.update("apply")
        self.assertEqual((code, out["last"]["verdict"], out["last"]["reason"]), (0, "no_update", "not_in_rollout"))
        self.assertEqual(self.live_version(CODING), "1.0.0")

    def test_malformed_pin_file_fails_closed(self):
        _, comps = self.release("v1")
        folder = self.stage(11, comps)
        for broken in ({"checkpoint": {"min_bundle_version": -1}}, {"checkpoint": {"min_seq": 1}},
                       {"checkpoint": []}, {"revoked_key_ids": "TEST-release-1"},
                       {"revoked_key_ids": [RELEASE, RELEASE]}, {"pinned_by": "bot"}):
            with self.subTest(broken):
                self.write_pins(**broken)
                code, out = self.update("apply", "--staged", str(folder))
                self.assertEqual((code, out["reason"]), (78, "pins_unusable"))
        self.pins_path.write_text("{}")
        self.assertEqual(self.update("check")[0], 78)
        self.pins_path.unlink()
        self.assertEqual(self.update("verify")[0], 78)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.category().exists())

    @unittest.skipIf(os.geteuid() == 0, "root can write anything")
    def test_pin_protection_is_reported(self):
        self.pending_12()
        self.assertFalse(self.status()["pins"]["protected"])
        self.pins_path.chmod(0o444)
        self.prefix.chmod(0o555)
        self.addCleanup(self.prefix.chmod, 0o755)
        self.update("check")
        self.assertTrue(self.status()["pins"]["protected"])

    def test_keys_signed_by_an_unpinned_root_are_refused(self):
        _, comps = self.release("v1")
        self.refused(self.stage(11, comps, keys=key_manifest(root="TEST-rogue")), "keys_untrusted")
        self.assertEqual(self.floors(), {})


if __name__ == "__main__":
    unittest.main()
