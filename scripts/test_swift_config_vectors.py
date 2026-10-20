"""P6a parity guard: the config vectors, the Python reference decoder and the Swift sources agree, without Swift.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_config_vectors.py

Every case in Tests/Fixtures/release-bundles/config/vectors.json is decoded by scripts/release/config_reference.py
and must give the expected reads, kill states and reports; the signed bundle 12 goes through the P0b verifier
first. The Swift decoder's denylist, kill scopes, key pattern and size limit are compared with the reference, and
the Swift tests must read every case. This checks expectations and source rules, not Swift execution: the Mac run
(`swift test`) remains mandatory.
"""

import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
CATALOG = json.loads((FIXTURES / "config/vectors.json").read_text(encoding="utf-8"))
CORE = ROOT / "Packages/SwarmHubCore"
UPDATES = CORE / "Sources/SwarmHubCore/Updates"
DECODER = (UPDATES / "ConfigDecoder.swift").read_text(encoding="utf-8")
STORE = (UPDATES / "ConfigStore.swift").read_text(encoding="utf-8")
TESTS = [CORE / "Tests/SwarmHubCoreTests" / name for name in ("ConfigStoreTests.swift", "ConfigStoreBundleTests.swift")]
sys.path.insert(0, str(ROOT / "scripts/release"))
sys.path.insert(0, str(ROOT / "Resources/Updater"))
import build_bundle  # noqa: E402
import config_reference  # noqa: E402
import make_config_vectors  # noqa: E402
import make_vectors  # noqa: E402
from swarmhub_update import verify  # noqa: E402


def swift_strings(name, source=DECODER):
    body = re.search(rf"static let {name}[^=]*= \[(.*?)\]", source, re.S).group(1)
    return re.findall(r'"([^"]*)"', body)


def archives():
    return {c["archive"]: (FIXTURES / c["archive"]).read_bytes()
            for case in CATALOG["cases"] for c in case["components"] if "archive" in c}


class CaseTests(unittest.TestCase):
    pass


def case_test(case):
    def test(self):
        self.assertEqual(make_config_vectors.check_case(case, archives()), [])
    return test


for vector in CATALOG["cases"]:
    setattr(CaseTests, "test_" + vector["id"].replace("-", "_"), case_test(vector))


class SignedBundleTests(unittest.TestCase):
    def test_bundle_12_verifies_with_test_keys_and_reads_only_app_config(self):
        case = CATALOG["bundle"]
        i = case["inputs"]
        result = verify.verify_release(
            (FIXTURES / i["pins"]).read_bytes(), (FIXTURES / i["keys"]).read_bytes(), (FIXTURES / i["index"]).read_bytes(),
            fetch_manifest=lambda line: (FIXTURES / i["manifest"]).read_bytes(),
            fetch_blob=lambda c: (FIXTURES / i["blobs"] / c["sha256"]).read_bytes(),
            channel=i["channel"], now=i["now"], floors=i["floors"], consumer=i["consumer"],
            install_id=i["install_id"], limits=config_reference.LIMITS)
        self.assertEqual((result["verdict"], result["bundle_version"], result["apply"]), ("accept", 12, case["apply"]))
        signed = json.loads((FIXTURES / i["manifest"]).read_bytes())["signed"]
        self.assertTrue(all(s["key_id"].startswith("TEST-")
                            for s in json.loads((FIXTURES / i["manifest"]).read_bytes())["signatures"]))
        self.assertIn("box-policy", [c["name"] for c in signed["components"]])  # present, but never an app document
        decoded = config_reference.decode([(name, result["blobs"][name]) for name in result["apply"]])
        self.assertEqual(make_config_vectors.check_result(decoded, case), [])


class SourceParityTests(unittest.TestCase):
    def test_swift_denylist_and_rules_match_the_reference(self):
        self.assertEqual(swift_strings("deniedFragments"), list(config_reference.DENIED_FRAGMENTS))
        self.assertEqual(set(swift_strings("deniedWords")), set(config_reference.DENIED_WORDS))
        self.assertEqual(set(swift_strings("killScopes")), set(config_reference.KILL_SCOPES))
        self.assertIn(f'static let keyPattern = "{config_reference.KEY_PATTERN.pattern}"', DECODER)
        self.assertIn(f"static let maxDocumentBytes = {config_reference.MAX_DOCUMENT_BYTES:_}", DECODER)
        self.assertIn("case " + ", ".join(config_reference.DOMAINS) + "\n", DECODER)  # order decides report order
        self.assertIn('"swarmhub/config-\\(rawValue)/1"', DECODER)
        for reason in ("component_unreadable", "component_not_data", "duplicate_document", "config_too_large",
                       "config_invalid", "schema_invalid", "invalid_kill", "invalid_key", "denied_key",
                       "denied_value", "wrong_type"):
            self.assertIn(f'"{reason}"', DECODER, reason)
        for reason in ("killed", "wrong_type", "out_of_range"):
            self.assertIn(f'"{reason}"', STORE, reason)

    def test_swift_tests_run_every_case_and_read_type(self):
        source = "\n".join(path.read_text(encoding="utf-8") for path in TESTS)
        self.assertIn('"config/vectors.json"', source)
        self.assertIn("for vector in cases", source)
        types = {read["type"] for case in CATALOG["cases"] + [CATALOG["bundle"]] for read in case["reads"]}
        self.assertEqual(types, {"string", "bool", "integer", "string_list", "string_map", "integer_map"})
        for kind in types:
            self.assertTrue(f'case ("{kind}",' in source, kind)
        for needle in ('"signed-bundle-12"', "unreachable", "ConfigStore()"):
            self.assertIn(needle, source)

    def test_sources_are_ios_safe_and_under_500_lines(self):
        for path in [UPDATES / "ConfigDecoder.swift", UPDATES / "ConfigStore.swift", UPDATES / "ArchiveRules.swift",
                     *TESTS, ROOT / "scripts/release/config_reference.py", ROOT / "scripts/release/config_vector_cases.py",
                     ROOT / "scripts/release/make_config_vectors.py", Path(__file__)]:
            source = path.read_text(encoding="utf-8")
            self.assertLessEqual(len(source.splitlines()), 500, path.name)
            if path.suffix == ".swift":
                self.assertNotRegex(source, r"\bimport\s+(AppKit|UIKit)\b|\bProcess\s*\(|JSContext|dlopen")


class FixtureTests(unittest.TestCase):
    def test_config_vectors_regenerate_byte_identically(self):
        self.assertEqual(make_config_vectors.main(["--check"]), 0)

    def test_existing_release_vectors_are_unchanged(self):
        self.assertEqual(make_vectors.main(["--check"]), 0)

    def test_release_built_app_config_decodes_without_reports(self):
        body, blobs = build_bundle.build(version=1, label="2026.10.1", created="2026-10-20T12:00:00Z", previous=None)
        app = [(c["name"], blobs[c["sha256"]]) for c in body["components"]
               if c["kind"] == "config" and {"mac", "ios"} & set(c["targets"])]
        self.assertIn("policy", [name for name, _ in app])
        decoded = config_reference.decode(app)
        self.assertEqual(decoded["reports"], [])
        policy = json.loads((ROOT / "scripts/release/policy_defaults.json").read_text(encoding="utf-8"))
        for key, kind in (("codingOrder", "string"), ("modelDefaults", "string_map"), ("teamActions", "string_list"),
                          ("teamLimits", "integer_map")):
            self.assertEqual(config_reference.read(decoded, "policy", key, kind, None), (policy[key], None))


if __name__ == "__main__":
    print(f"config vectors: {len(CATALOG['cases'])} cases + signed bundle {CATALOG['bundle']['id']}", flush=True)
    unittest.main()
