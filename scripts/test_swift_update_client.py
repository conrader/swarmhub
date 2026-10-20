"""P4a parity guard: re-derive the Swift fetch-client test expectations through P0b, without Swift or network.

    PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_swift_update_client.py

Every verifier-stage case in UpdateClientTests.matrix is replayed against the shared fixtures with the same byte
change and the same consumer, floors and clock, and must give the stage and reason the Swift test expects.
Transport cases (stage `fetch`) cannot run here and are only checked to exist. This checks expectations and
source rules, not Swift execution: the Mac run (`swift test`) remains mandatory.
"""

import hashlib
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Packages/SwarmHubCore"
TESTS = CORE / "Tests/SwarmHubCoreTests"
CLIENT_TEST = (TESTS / "UpdateClientTests.swift").read_text(encoding="utf-8")
FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
sys.path.insert(0, str(ROOT / "Resources/Updater"))
from swarmhub_update import verify  # noqa: E402

NEW_SOURCES = [CORE / "Sources/SwarmHubCore/Updates" / name
               for name in ("UpdateClient.swift", "UpdateStore.swift", "UpdateTransport.swift")]
NEW_TESTS = [TESTS / name for name in ("UpdateClientTests.swift", "UpdateStoreTests.swift", "UpdateTestSupport.swift")]
LIMITS = dict(max_blob_size=67108864, max_depth=16, max_entries=4096, max_file_size=8388608, max_path_bytes=255,
              max_signed_bytes=1048576, max_total_size=67108864)
CONSUMER_VERSIONS = {"app": "0.6.2", "config_schema": "2", "ui_catalog": "1.3"}


def read(path):
    return (FIXTURES / path).read_bytes()


def policy_sha():
    signed = json.loads(read("bundles/11.json"))["signed"]
    return next(c["sha256"] for c in signed["components"] if c["name"] == "policy")


def flip_first(data):
    return bytes([data[0] ^ 1]) + data[1:]


# name -> (target, transform). Targets: keys, index, manifest, or the policy blob.
VERIFIER_CASES = {
    "bad-index-signature": ("index", lambda _: read("channels/stable--tampered-byte.json")),
    "bad-keys-signature": ("keys", lambda _: read("keys/keys-2--tampered-byte.json")),
    "wrong-key": ("index", lambda _: read("channels/stable--wrong-key.json")),
    "wrong-channel": ("index", lambda _: read("channels/stable--beta.json")),
    "stale-index": ("index", lambda _: read("channels/stable--expired.json")),
    "truncated-keys": ("keys", lambda data: data[:200]),
    "truncated-manifest": ("manifest", lambda data: data[:-1]),
    "truncated-blob": ("policy", lambda data: data[:-1]),
    "tampered-blob": ("policy", flip_first),
}
FETCH_CASES = {"unreachable", "dns", "index-404", "manifest-404", "server-error", "redirect-same-host",
               "oversized-index", "oversized-blob"}


def client_verdict(platform="ios", floors=(1, 4, 10), now="2026-10-20T12:00:00Z", change=None):
    target, transform = change or (None, None)
    def bytes_for(name, data):
        return transform(data) if target == name else data
    fetched = []
    def fetch_manifest(line):
        fetched.append("manifest")
        return bytes_for("manifest", read(f"bundles/{line['bundle_version']}.json"))
    def fetch_blob(component):
        fetched.append(component["name"])
        return bytes_for(component["name"], read("blobs/sha256/" + component["sha256"]))
    result = verify.verify_release(
        read("keys/pins.json"), bytes_for("keys", read("keys/keys-2.json")),
        bytes_for("index", read("channels/stable.json")), fetch_manifest=fetch_manifest, fetch_blob=fetch_blob,
        channel="stable", now=now,
        floors={"keys_version": floors[0], "index_seq": floors[1], "bundle_version": floors[2]},
        consumer={"platform": platform, "versions": CONSUMER_VERSIONS}, install_id="TEST-install-0001",
        revoked_key_ids=[], limits=LIMITS)
    return result, fetched


def swift_matrix():
    rows = re.findall(r'MatrixCase\(name: "([^"]+)",.*?stage: "([^"]+)", reason: "([^"]+)"\)', CLIENT_TEST, re.S)
    return {name: (stage, reason) for name, stage, reason in rows}


class MatrixParityTests(unittest.TestCase):
    def test_matrix_names_are_exactly_the_known_cases(self):
        matrix = swift_matrix()
        self.assertEqual(set(matrix), set(VERIFIER_CASES) | FETCH_CASES)
        for name in FETCH_CASES:
            self.assertEqual(matrix[name][0], "fetch", name)

    def test_p3a_failure_matrix_is_covered(self):
        # P3a: unreachable, 404, redirect refused, bad signature, rollback below floor, oversized, truncated,
        # wrong channel, stale.
        matrix = swift_matrix()
        reasons = {reason for _, reason in matrix.values()}
        for reason in ("unreachable", "http_404", "redirect_refused", "bad_signature", "oversize",
                       "channel_mismatch", "index_expired", "blob_size_mismatch", "schema_invalid"):
            self.assertIn(reason, reasons)
        for literal in ('"index_rollback"', '"bundle_rollback"', '"keys_rollback"',
                        "redirectToAnotherHostIsRefusedAndNeverFollowed", "staleSinceIsTheExpiryOfTheLastVerifiedIndex"):
            self.assertIn(literal, CLIENT_TEST)

    def test_valid_chain_for_apps_takes_only_data_components(self):
        for platform in ("ios", "mac"):
            result, fetched = client_verdict(platform)
            self.assertEqual((result["verdict"], result["apply"]), ("accept", ["policy", "routine-card"]))
            self.assertEqual(fetched, ["manifest", "policy", "routine-card"])
            self.assertEqual(sorted(result["blobs"]), ["policy", "routine-card"])

    def test_floor_and_freshness_cases(self):
        for floors, stage, reason in (((1, 6, 10), "index", "index_rollback"), ((1, 4, 12), "index", "bundle_rollback"),
                                      ((3, 4, 10), "keys", "keys_rollback")):
            result, fetched = client_verdict(floors=floors)
            self.assertEqual((result["stage"], result["reason"]), (stage, reason))
            self.assertEqual(fetched, [])
        self.assertEqual(client_verdict(floors=(2, 5, 11))[0]["reason"], "already_applied")
        self.assertEqual(client_verdict(now="2026-10-27T00:00:00Z")[0]["reason"], "index_expired")
        signed = json.loads(read("channels/stable.json"))["signed"]
        self.assertEqual((signed["expires"], signed["seq"]), ("2026-10-26T00:00:00Z", 5))
        self.assertEqual(json.loads(read("keys/keys-2.json"))["signed"]["version"], 2)

    def test_swift_support_reads_the_same_bytes(self):
        support = (TESTS / "UpdateTestSupport.swift").read_text(encoding="utf-8")
        for path in ('"keys/keys-2.json"', '"channels/stable.json"', '"bundles/11.json"', '"keys/pins.json"'):
            self.assertIn(path, support)
        self.assertEqual(hashlib.sha256(read("blobs/sha256/" + policy_sha())).hexdigest(), policy_sha())


class VerifierCaseTests(unittest.TestCase):
    pass


def verifier_case(name):
    def test(self):
        result, _ = client_verdict(change=VERIFIER_CASES[name])
        self.assertEqual(result["verdict"], "reject")
        self.assertEqual((result["stage"], result["reason"]), swift_matrix()[name])
    return test


for case_name in VERIFIER_CASES:
    setattr(VerifierCaseTests, "test_" + case_name.replace("-", "_"), verifier_case(case_name))


class SourceRuleTests(unittest.TestCase):
    def test_ios_safe_nothing_executed_and_under_500_lines(self):
        for path in NEW_SOURCES + NEW_TESTS + [Path(__file__)]:
            source = path.read_text(encoding="utf-8")
            self.assertLessEqual(len(source.splitlines()), 500, path.name)
            if path.suffix != ".swift":
                continue
            self.assertNotRegex(source, r"\bimport\s+(AppKit|UIKit|JavaScriptCore|WebKit)\b", path.name)
            self.assertNotRegex(source, r"\bProcess\s*\(|\bNSTask\b|\bdlopen\b|\bposix_spawn|\bBundle\s*\(\s*(path|url)"
                                        r"|\bJSContext\b|\bNSAppleScript\b|\bsystem\s*\(", path.name)

    def test_transport_keeps_the_managed_remote_control_discipline(self):
        transport = NEW_SOURCES[2].read_text(encoding="utf-8")
        for needle in ("URLSessionConfiguration.ephemeral", "httpCookieStorage = nil", "urlCredentialStorage = nil",
                       "urlCache = nil", '"no-store"', "willPerformHTTPRedirection", "task.cancel()",
                       "completionHandler(nil)", "http.url == url", 'parts.scheme == "https"', "delegate: redirects"):
            self.assertIn(needle, transport)


if __name__ == "__main__":
    unittest.main()
