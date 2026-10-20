"""P6a parity guard: the config vectors, the Python reference decoder and the Swift sources agree, without Swift.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_config_vectors.py

Every case in Tests/Fixtures/release-bundles/config/vectors.json is decoded by scripts/release/config_reference.py
and must give the expected reads, kill states and reports; the signed bundle 12 goes through the P0b verifier
first. The Swift decoder's denylist, kill scopes, key pattern and size limit are compared with the reference, and
the Swift tests must read every case. This checks expectations and source rules, not Swift execution: the Mac run
(`swift test`) remains mandatory.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
CATALOG = json.loads((FIXTURES / "config/vectors.json").read_text(encoding="utf-8"))
CORE = ROOT / "Packages/SwarmHubCore"
UPDATES = CORE / "Sources/SwarmHubCore/Updates"
DECODER = (UPDATES / "ConfigDecoder.swift").read_text(encoding="utf-8")
STORE = (UPDATES / "ConfigStore.swift").read_text(encoding="utf-8")
TESTS = [CORE / "Tests/SwarmHubCoreTests" / name for name in
         ("ConfigStoreTests.swift", "ConfigStoreBundleTests.swift", "ConfigStoreSnapshotTests.swift")]
sys.path.insert(0, str(ROOT / "scripts/release"))
sys.path.insert(0, str(ROOT / "Resources/Updater"))
import build_bundle  # noqa: E402
import config_reference  # noqa: E402
import make_config_vectors  # noqa: E402
import make_vectors  # noqa: E402
import ustar  # noqa: E402
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


class SnapshotTests(unittest.TestCase):
    """The live snapshot rule, using temporary store directories and deterministic read interleavings."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.a = self.bundle(12, 3, True)
        self.b = self.bundle(13, 7, False)
        self.switch(self.a)

    def bundle(self, version, limit, killed):
        directory = self.root / f"versions/{version}-{'a' * 16}"
        (directory / "components").mkdir(parents=True)
        documents = {
            "policy": {"codingOrder": f"TEST-{version}", "coding_job_limit": limit, "autoRoutines": True},
            "flags": {"routineCards": True, "kill.policy.codingOrder": killed, "kill.view.routine_card": killed},
        }
        entries = []
        for name, members in documents.items():
            data = json.dumps(dict(schema=f"swarmhub/config-{name}/1", **members)).encode()
            archive = ustar.build([dict(name=f"{name}.json", type="file", mode=0o644, data=data)])
            (directory / "components" / name).write_bytes(archive)
            entries.append(dict(name=name, kind="config", **{"class": "data"}, version="1.0.0", size=len(archive),
                                sha256=hashlib.sha256(archive).hexdigest()))
        (directory / "record.json").write_text(json.dumps(dict(
            bundle_version=version, manifest_sha256="a" * 64, applied_at="2026-10-20T12:00:00Z",
            platform="ios", components=entries)))
        return directory

    def switch(self, directory):
        link = self.root / ".current-next"
        link.symlink_to(directory.relative_to(self.root))
        os.replace(link, self.root / "current")

    def assert_defaults(self, result):
        self.assertIsNone(result["bundle_version"])
        self.assertEqual(result["values"], {})
        self.assertEqual(result["killed_keys"], set())
        self.assertEqual(result["killed_views"], set())
        self.assertEqual(config_reference.read(result, "policy", "codingOrder", "string", "compiled"), ("compiled", None))
        self.assertEqual(config_reference.read(result, "policy", "autoRoutines", "bool", False), (False, None))
        self.assertEqual(config_reference.read(result, "policy", "coding_job_limit", "integer", 1), (1, None))
        self.assertEqual(config_reference.read(result, "flags", "routineCards", "bool", False), (False, None))

    def test_switch_after_record_or_between_components_pins_one_bundle_and_reads_once(self):
        for switch_before in ("policy", "flags"):
            with self.subTest(switch_before=switch_before):
                self.switch(self.a)
                reads = []
                def hook(name):
                    reads.append(name)
                    if name == switch_before:
                        self.switch(self.b)
                byte_reads, read_bytes = [], Path.read_bytes
                def counted(path):
                    byte_reads.append(path)
                    return read_bytes(path)
                with patch.object(Path, "read_bytes", counted):
                    result = config_reference.snapshot(self.root, hook)
                self.assertEqual(reads, ["policy", "flags"])
                self.assertEqual(byte_reads, [self.a / "record.json", self.a / "components/policy", self.a / "components/flags"])
                self.assertEqual(result["bundle_version"], 12)
                self.assertEqual(result["reports"], [])
                self.assertEqual(config_reference.read(result, "policy", "coding_job_limit", "integer", 1), (3, None))
                self.assertEqual(config_reference.read(result, "policy", "codingOrder", "string", "compiled"), ("compiled", "killed"))
                self.assertEqual(result["killed_views"], {"routine_card"})
                after = config_reference.snapshot(self.root)
                self.assertEqual(after["bundle_version"], 13)
                self.assertEqual(after["killed_keys"], set())

    def failed_read(self, failure):
        reads = []
        def hook(name):
            reads.append(name)
            if name != "flags":
                return
            flags = self.a / "components/flags"
            if failure == "collected":
                self.switch(self.b)
                shutil.rmtree(self.a)
            elif failure == "missing":
                flags.unlink()
            elif failure == "size":
                flags.write_bytes(b"")
            else:
                data = bytearray(flags.read_bytes())
                data[600] ^= 1
                flags.write_bytes(data)
        result = config_reference.snapshot(self.root, hook)
        self.assert_defaults(result)
        self.assertEqual(reads, ["policy", "flags"])
        self.assertEqual(result["reports"], [dict(reason="component_unreadable", component="flags")])

    def test_collection_discards_already_read_policy(self):
        self.failed_read("collected")

    def test_missing_component_discards_already_read_policy(self):
        self.failed_read("missing")

    def test_hash_mismatch_discards_already_read_policy(self):
        self.failed_read("hash")

    def test_size_mismatch_discards_already_read_policy(self):
        self.failed_read("size")

    def test_pinned_record_is_read_only_once(self):
        def hook(name):
            if name == "policy":
                (self.a / "record.json").unlink()
        result = config_reference.snapshot(self.root, hook)
        self.assertEqual(result["bundle_version"], 12)
        self.assertEqual(result["reports"], [])
        self.assertEqual(result["killed_keys"], {"policy.codingOrder"})

    def test_failed_policy_discards_already_read_kill_flags(self):
        record_path = self.a / "record.json"
        record = json.loads(record_path.read_bytes())
        record["components"].reverse()
        record_path.write_text(json.dumps(record))
        reads = []
        def hook(name):
            reads.append(name)
            if name == "policy":
                (self.a / "components/policy").unlink()
        result = config_reference.snapshot(self.root, hook)
        self.assert_defaults(result)
        self.assertEqual(reads, ["flags", "policy"])
        self.assertEqual(result["reports"], [dict(reason="component_unreadable", component="policy")])

    def test_missing_pinned_record_reports_whole_snapshot_failure(self):
        shutil.rmtree(self.a)
        result = config_reference.snapshot(self.root)
        self.assert_defaults(result)
        self.assertEqual(result["reports"], [dict(reason="bundle_unreadable")])

    def assert_bad_record(self, record):
        (self.a / "record.json").write_text(json.dumps(record))
        reads = []
        result = config_reference.snapshot(self.root, reads.append)
        self.assert_defaults(result)
        self.assertEqual(result["reports"], [dict(reason="bundle_unreadable")])
        self.assertEqual(reads, [])

    def test_record_and_component_containers_must_be_objects(self):
        original = json.loads((self.a / "record.json").read_bytes())
        for value in (None, False, 12, "record", []):
            with self.subTest(value=value):
                self.assert_bad_record(value)
                record = dict(original, components=[original["components"][0], value])
                self.assert_bad_record(record)

    def test_invalid_skipped_component_also_rejects_the_bundle(self):
        record = json.loads((self.a / "record.json").read_bytes())
        skipped = dict(record["components"][0], kind="ui")
        del skipped["version"]
        record["components"].append(skipped)
        self.assert_bad_record(record)

    def test_unknown_fields_and_unvalidated_strings_remain_accepted(self):
        record = json.loads((self.a / "record.json").read_bytes())
        # Codable checks types here, not hash/date/platform/version syntax or unknown members.
        record.update(manifest_sha256="", applied_at="", platform="TEST-unknown", extra=None)
        for entry in record["components"]:
            entry.update(version="", extra=None)
        (self.a / "record.json").write_text(json.dumps(record))
        result = config_reference.snapshot(self.root)
        self.assertEqual(result["bundle_version"], 12)
        self.assertEqual(result["reports"], [])
        self.assertEqual(result["killed_views"], {"routine_card"})

    def test_int64_bounds_and_integral_json_numbers(self):
        path = self.a / "record.json"
        original = path.read_text()
        for number, expected in (("-9223372036854775808", -(2 ** 63)), ("9223372036854775807", 2 ** 63 - 1),
                                 ("12.0", 12), ("1.2e1", 12)):
            with self.subTest(number=number):
                path.write_text(original.replace('"bundle_version": 12', f'"bundle_version": {number}'))
                result = config_reference.snapshot(self.root)
                self.assertEqual(result["bundle_version"], expected)
                self.assertEqual(result["reports"], [])
        for number in ("12.5", "12.0000000000000000001", "1e9999999999999999999", "NaN", "Infinity"):
            with self.subTest(number=number):
                path.write_text(original.replace('"bundle_version": 12', f'"bundle_version": {number}'))
                result = config_reference.snapshot(self.root)
                self.assert_defaults(result)
                self.assertEqual(result["reports"], [dict(reason="bundle_unreadable")])


def record_field_test(component, field, kind, missing):
    def test(self):
        path = self.a / "record.json"
        original = path.read_bytes()
        invalid = [None, True, False, 1.5, {}]
        if kind != "[Component]":
            invalid.append([])
        invalid += ["12", -(2 ** 63) - 1, 2 ** 63] if kind == "Int64" else [12]
        if kind != "String":
            invalid.append("wrong")
        for value in ([None] if missing else invalid):
            with self.subTest(value=value):
                record = json.loads(original)
                target = record["components"][-1] if component else record
                if missing:
                    del target[field]
                else:
                    target[field] = value
                self.assert_bad_record(record)
    return test


for is_component, fields in ((False, config_reference.RECORD_FIELDS), (True, config_reference.COMPONENT_FIELDS)):
    for field_name, field_kind in fields.items():
        for is_missing in (True, False):
            test_name = "test_" + ("missing_" if is_missing else "wrong_type_")
            test_name += ("component_" if is_component else "record_") + field_name
            setattr(SnapshotTests, test_name, record_field_test(is_component, field_name, field_kind, is_missing))


class SourceParityTests(unittest.TestCase):
    def test_record_required_fields_and_types_match_swift_codable(self):
        updates = (UPDATES / "UpdateStore.swift").read_text(encoding="utf-8")
        record = updates[updates.index("public struct UpdateRecord:"):updates.index("/// Everything one commit writes:")]
        component = record[record.index("public struct Component:"):record.index("    public let bundleVersion:")]
        outer = record[record.index("    public let bundleVersion:"):]
        for source, expected in ((outer, config_reference.RECORD_FIELDS), (component, config_reference.COMPONENT_FIELDS)):
            with self.subTest(fields=expected):
                self.assertNotIn("init(from", record)  # The reference mirrors synthesized Codable only.
                fields = re.findall(r"public let (\w+): ([\w\[\]?]+)", source)
                self.assertEqual(len(fields), len(expected))
                aliases = dict(re.findall(r'(\w+) = "([^"]+)"', source))
                self.assertEqual({aliases.get(name, name): kind for name, kind in fields}, expected)
                self.assertIn("Codable", record)
                self.assertIn("enum CodingKeys: String, CodingKey", source)

    def test_swift_snapshot_pins_record_and_directory_and_fails_closed(self):
        updates = (UPDATES / "UpdateStore.swift").read_text(encoding="utf-8")
        initializer = STORE[STORE.index("public convenience init(updates:"):STORE.index("/// Decoder-only")]
        self.assertEqual(initializer.count("updates.pinnedBundle()"), 1)
        self.assertNotIn("updates.record(", initializer)
        self.assertNotIn("updates.component(", initializer)
        for needle in ("bundle?.record.components", "bundle?.component($0.name)", "$0.archive == nil",
                       'ConfigReport(reason: "component_unreadable"', "ConfigDocuments(reports: failures)",
                       'ConfigReport(reason: "bundle_unreadable")'):
            self.assertIn(needle, initializer)
        pinned = updates[updates.index("func pinnedBundle("):updates.index("/// The stored archive bytes")]
        self.assertEqual(pinned.count("target(slot.rawValue)"), 1)
        self.assertEqual(pinned.count("JSONDecoder().decode(UpdateRecord.self"), 1)
        self.assertEqual(pinned.count("Data(contentsOf: url)"), 1)
        for needle in ("directory.appendingPathComponent", "Int64(data.count) == entry.size",
                       "updateDigest(data) == entry.sha256", "try beforeComponentRead?(name)"):
            self.assertIn(needle, pinned)
        source = TESTS[-1].read_text(encoding="utf-8")
        for needle in ("switchAfterRecordOrBetweenComponentsKeepsOneBundle", "failedPinnedReadDiscardsAllValuesAndKills",
                       "pinnedRecordIsReadOnlyOnce", "missingPinnedRecordReportsWholeSnapshotFailure",
                       "failedPolicyDiscardsAlreadyReadKillFlags",
                       '["policy", "flags"]', '["missing", "hash", "size", "collected"]'):
            self.assertIn(needle, source)

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
        for path in [UPDATES / "ConfigDecoder.swift", UPDATES / "ConfigStore.swift", UPDATES / "UpdateStore.swift", UPDATES / "ArchiveRules.swift",
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
