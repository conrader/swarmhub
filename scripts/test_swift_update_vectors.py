"""P0c parity guard: run the exact Swift test catalogue through P0b, without Swift or network.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_update_vectors.py

This checks shared expectations, not Swift execution. Mac checks remain mandatory.
"""

import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SWIFT_TEST = ROOT / "Packages/SwarmHubCore/Tests/SwarmHubCoreTests/UpdateVerifierTests.swift"
SWIFT_SOURCE = SWIFT_TEST.read_text(encoding="utf-8")
FIXTURE_PATH = re.search(r'static let vectorFixture = "([^"]+)"', SWIFT_SOURCE).group(1)
FIXTURES = (ROOT / FIXTURE_PATH).parent
CATALOG = json.loads((ROOT / FIXTURE_PATH).read_text(encoding="utf-8"))
sys.path.insert(0, str(ROOT / "Resources/Updater"))
from swarmhub_update import jcs, verify  # noqa: E402


def release_verdict(case):
    i = case["inputs"]
    result = verify.verify_release(
        (FIXTURES / i["pins"]).read_bytes(), (FIXTURES / i["keys"]).read_bytes(),
        (FIXTURES / i["index"]).read_bytes(),
        fetch_manifest=lambda line: (FIXTURES / i["manifest"]).read_bytes(),
        fetch_blob=lambda c: (FIXTURES / "blobs/sha256" / c["sha256"]).read_bytes(),
        channel=i["channel"], now=i["now"], floors=i["floors"], consumer=i["consumer"],
        install_id=i["install_id"], revoked_key_ids=i["revoked_key_ids"], limits=i["limits"])
    return {key: value for key, value in result.items() if key not in ("manifest", "blobs")}


class SwiftCatalogueTests(unittest.TestCase):
    def test_swift_reads_every_shared_case_and_expected_verdict(self):
        self.assertEqual(FIXTURE_PATH, "Tests/Fixtures/release-bundles/vectors.json")
        self.assertIn("for vector in catalog.cases {", SWIFT_SOURCE)
        self.assertIn("result.verdict == vector.expect", SWIFT_SOURCE)
        self.assertIn("for vector in catalog.jcs {", SWIFT_SOURCE)
        self.assertIn("JCS.canonical(JCS.parse(Data(vector.input.utf8)))", SWIFT_SOURCE)
        for group in ("cases", "jcs"):
            ids = [v["id"] for v in CATALOG[group]]
            self.assertTrue(ids)
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(len(ids), len({value.replace("-", "_") for value in ids}))

    def test_new_sources_are_ios_safe_and_under_500_lines(self):
        sources = list((ROOT / "Packages/SwarmHubCore/Sources/SwarmHubCore/Updates").glob("*.swift"))
        self.assertTrue(sources)
        for path in sources + [SWIFT_TEST, Path(__file__)]:
            source = path.read_text(encoding="utf-8")
            self.assertLessEqual(len(source.splitlines()), 500, path.name)
            if path.suffix == ".swift":
                self.assertNotRegex(source, r"\bimport\s+(AppKit|UIKit)\b|\bProcess\s*\(")


class ReleaseVectorTests(unittest.TestCase):
    pass


class CanonicalVectorTests(unittest.TestCase):
    pass


def release_test(case):
    def test(self):
        self.assertEqual(release_verdict(case), case["expect"])
    return test


def canonical_test(vector):
    def test(self):
        if vector.get("error"):
            with self.assertRaises(jcs.JCSError):
                jcs.loads(vector["input"])
        else:
            self.assertEqual(jcs.canonical(jcs.loads(vector["input"])), vector["canonical"].encode("utf-8"))
    return test


# One counted test per vector, so failures and counts identify the whole Swift catalogue.
for vector in CATALOG["cases"]:
    setattr(ReleaseVectorTests, "test_" + vector["id"].replace("-", "_"), release_test(vector))
for vector in CATALOG["jcs"]:
    setattr(CanonicalVectorTests, "test_" + vector["id"].replace("-", "_"), canonical_test(vector))


if __name__ == "__main__":
    print(f"Swift catalogue: {len(CATALOG['cases'])} release vectors, {len(CATALOG['jcs'])} JCS vectors", flush=True)
    unittest.main()
