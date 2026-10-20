"""P1c adapters: no sockets, credentials, containers or gh processes."""

import copy
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from test_release_publish import Service, BOX, MAC, IOS, ISSUED, EXPIRES, NOW

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))
import backends
from github_backend import GitHubBackend, materialize
import jcs
import publish
import republish
from s3_backend import S3Client
from sign import p0b


class FakeStore:
    """Atomic in-process S3 stand-in; faults before OR after every put and read."""

    def __init__(self):
        self.data, self.headers, self.calls = {}, {}, []
        self.fail_at, self.after, self.steps = None, False, 0
        self.corrupt = None
        self.race = None

    def operation(self, action):
        self.steps += 1
        if self.steps == self.fail_at and not self.after:
            raise OSError("injected storage failure")
        result = action()
        if self.steps == self.fail_at and self.after:
            raise OSError("injected storage failure after commit")
        return result

    def get(self, key):
        def action():
            self.calls.append(("get", key))
            if key not in self.data:
                return None
            data = b"corrupt" if key == self.corrupt else self.data[key]
            return data, hashlib.sha256(data).hexdigest()
        return self.operation(action)

    def put(self, key, data, **kwargs):
        def action():
            if self.race:
                self.data[key] = self.race
                self.race = None
            if kwargs["if_none_match"]:
                if key in self.data:
                    raise backends.BackendError("precondition failed")
            elif key not in self.data or hashlib.sha256(self.data[key]).hexdigest() != kwargs["if_match"]:
                raise backends.BackendError("precondition failed")
            self.calls.append(("put", key))
            self.data[key], self.headers[key] = data, kwargs
        return self.operation(action)


def verify(service, data, consumer=BOX):
    return p0b.verify_release(service.pins, data["keys.json"], data["channels/stable.json"],
                             fetch_manifest=lambda line: data[f"bundles/{line['bundle_version']}.json"],
                             fetch_blob=lambda c: data[f"blobs/sha256/{c['sha256']}"], channel="stable", now=NOW,
                             floors={"keys_version": 1, "index_seq": 1, "bundle_version": 0},
                             consumer=consumer, install_id="TEST-install-0001")


def assert_closed(test, data):
    for path, raw in data.items():
        if path.startswith("channels/"):
            for line in jcs.loads(raw)["signed"]["lines"]:
                manifest = data[f"bundles/{line['bundle_version']}.json"]
                test.assertEqual(hashlib.sha256(manifest).hexdigest(), line["manifest_sha256"])
                for component in jcs.loads(manifest)["signed"]["components"]:
                    blob = data[f"blobs/sha256/{component['sha256']}"]
                    test.assertEqual(hashlib.sha256(blob).hexdigest(), component["sha256"])


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.service = Service(self)
        self.body, self.blobs = self.service.build_and_publish()
        # Start the adapter publication from the same pre-release state.
        self.source = self.service.snapshot()
        (self.service.repo / "bundles/1.json").unlink()
        (self.service.repo / "channels/stable.json").unlink()
        self.store = FakeStore()
        self.backend = backends.ObjectStoreBackend(self.store)

    def test_store_order_cache_and_p0b_identical_for_all_consumers(self):
        self.service.publish(self.body, self.blobs, backend=self.backend)
        puts = [p for action, p in self.store.calls if action == "put"]
        self.assertEqual(puts[-1], "channels/stable.json")
        blob_end = max(i for i, p in enumerate(puts) if p.startswith("blobs/"))
        manifest_start = min(i for i, p in enumerate(puts) if p.startswith("bundles/"))
        self.assertLess(blob_end, manifest_start)
        self.assertEqual(self.store.data, self.source)
        for path, headers in self.store.headers.items():
            immutable = path.startswith(("blobs/", "bundles/"))
            self.assertEqual(headers["cache_control"], backends.IMMUTABLE_CACHE if immutable else backends.MUTABLE_CACHE)
            self.assertTrue(headers["if_none_match"])
        for consumer in (BOX, MAC, IOS):
            self.assertEqual(verify(self.service, self.store.data, consumer), verify(self.service, self.source, consumer))

    def test_existing_identical_immutable_objects_are_skipped(self):
        self.store.data = {k: v for k, v in self.source.items() if k.startswith(("blobs/", "bundles/"))}
        self.service.publish(self.body, self.blobs, backend=self.backend)
        puts = [p for action, p in self.store.calls if action == "put"]
        self.assertEqual(puts, ["keys.json", "channels/stable.json"])

    def test_differing_blob_and_manifest_refused_before_any_put(self):
        for path in ("bundles/1.json", next(k for k in self.source if k.startswith("blobs/"))):
            with self.subTest(path=path):
                store = FakeStore()
                store.data[path] = b"other bytes"
                with self.assertRaisesRegex(backends.BackendError, "never overwritten"):
                    self.service.publish(self.body, self.blobs, backend=backends.ObjectStoreBackend(store))
                self.assertFalse(any(a == "put" for a, _ in store.calls))
                self.assertFalse((self.service.repo / "channels/stable.json").exists())

    def test_failure_before_and_after_every_store_operation_never_dangles(self):
        # Include both empty stores and an existing published channel.
        for populated in (False, True):
            body = copy.deepcopy(self.body)
            body["version"] = 2
            body["label"] = "second"
            for after in (False, True):
                baseline = self.source if populated else {}
                store = FakeStore()
                store.data = dict(baseline)
                old_index = publish.read_index(self.service.repo, "stable")
                line = {"requires": body["requires"], "bundle_version": 2, "rollout_percent": 100,
                        "manifest_sha256": hashlib.sha256(publish.sign.envelope(body, [self.service.signer("TEST-release-1")])).hexdigest()}
                index = publish.next_index(old_index, "stable", line, seq=2, issued=ISSUED, expires=EXPIRES, replace_lines=True)
                objects = backends.release_objects(self.service.repo, body, self.blobs,
                    publish.sign.envelope(body, [self.service.signer("TEST-release-1")]),
                    publish.sign.envelope(index, [self.service.signer("TEST-release-1")]),
                    publish.load_trust(self.service.repo, self.service.pins)[1], ISSUED)
                backends.ObjectStoreBackend(store).publish(objects)
                for step in range(1, store.steps + 1):
                    with self.subTest(populated=populated, after=after, step=step):
                        broken = FakeStore()
                        broken.data, broken.fail_at, broken.after = dict(baseline), step, after
                        with self.assertRaises(OSError):
                            backends.ObjectStoreBackend(broken).publish(objects)
                        assert_closed(self, broken.data)
                        # A retry must finish safely after an ambiguous timeout too.
                        broken.fail_at = None
                        backends.ObjectStoreBackend(broken).publish(objects)
                        assert_closed(self, broken.data)

    def test_cas_race_never_overwrites_an_immutable_object(self):
        self.store.race = b"racing writer"
        with self.assertRaisesRegex(backends.BackendError, "precondition failed"):
            self.service.publish(self.body, self.blobs, backend=self.backend)
        self.assertNotIn("channels/stable.json", self.store.data)
        self.assertIn(b"racing writer", self.store.data.values())

    def test_retained_line_dependencies_uploaded_to_empty_store(self):
        self.service.publish(self.body, self.blobs)
        fresh = copy.deepcopy(self.body)
        fresh["version"] = 2
        self.service.publish(fresh, self.blobs, line_requires={"updater": ">=2.0"}, backend=self.backend)
        self.assertIn("bundles/1.json", self.store.data)
        self.assertIn("bundles/2.json", self.store.data)
        self.assertEqual(verify(self.service, self.store.data)["bundle_version"], 1)
        assert_closed(self, self.store.data)

    def test_missing_retained_dependency_stops_before_upload(self):
        self.service.publish(self.body, self.blobs)
        (self.service.repo / "bundles/1.json").unlink()
        fresh = copy.deepcopy(self.body)
        fresh["version"] = 2
        with self.assertRaises(OSError):
            self.service.publish(fresh, self.blobs, line_requires={"updater": ">=2.0"}, backend=self.backend)
        self.assertEqual(self.store.calls, [])

    def test_newer_remote_index_is_not_replayed(self):
        self.store.data = dict(self.source)
        raw = jcs.loads(self.store.data["channels/stable.json"])
        raw["signed"]["seq"] = 99
        self.store.data["channels/stable.json"] = jcs.canonical(raw)
        with self.assertRaisesRegex(backends.BackendError, "remote index seq"):
            self.service.publish(self.body, self.blobs, backend=self.backend)
        self.assertFalse(any(a == "put" for a, _ in self.store.calls))

    def test_read_back_corruption_prevents_index_and_local_advance(self):
        original = self.store.put
        def corrupt(key, data, **kwargs):
            original(key, data, **kwargs)
            if key.startswith("blobs/"):
                self.store.corrupt = key
        with patch.object(self.store, "put", side_effect=corrupt):
            with self.assertRaisesRegex(backends.BackendError, "read-back differs"):
                self.service.publish(self.body, self.blobs, backend=self.backend)
        self.assertNotIn("channels/stable.json", self.store.data)
        self.assertFalse((self.service.repo / "channels/stable.json").exists())

    def test_newer_remote_keys_cannot_be_replaced(self):
        raw = jcs.loads(self.source["keys.json"])
        raw["signed"]["version"] = 99
        self.store.data["keys.json"] = jcs.canonical(raw)
        with self.assertRaisesRegex(backends.BackendError, "remote key manifest version"):
            self.service.publish(self.body, self.blobs, backend=self.backend)
        self.assertFalse(any(a == "put" for a, _ in self.store.calls))

    def test_primary_success_mirror_failure_is_complete_and_retryable(self):
        from unittest.mock import Mock
        failed = Mock()
        failed.publish.side_effect = OSError("mirror failure")
        with self.assertRaises(OSError):
            self.service.publish(self.body, self.blobs, backend=backends.CompositeBackend(self.backend, failed))
        assert_closed(self, self.store.data)
        self.assertFalse((self.service.repo / "channels/stable.json").exists())
        mirror = GitHubBackend("TEST-owner/TEST-mirror", "bundle-1", self.service.dir / "mirror", dry_run=True)
        self.service.publish(self.body, self.blobs, backend=backends.CompositeBackend(self.backend, mirror))
        self.assertEqual(verify(self.service, self.store.data)["verdict"], "accept")
        self.assertFalse(mirror.state["draft"])

    def test_publish_cli_wires_github_dry_run(self):
        build = self.service.dir / "build"
        publish.build_bundle.write_build(build, self.body, {c["sha256"]: self.blobs[c["name"]]
                                                         for c in self.body["components"]})
        pins = self.service.dir / "pins.json"
        pins.write_bytes(self.service.pins)
        mirror, calls = self.service.dir / "mirror", self.service.dir / "calls.json"
        args = ["--repo", str(self.service.repo), "--pins", str(pins), "--build", str(build), "--version", "1",
                "--signer", f"file:{self.service.keydir / 'TEST-release-1'}", "--channel", "stable",
                "--issued", ISSUED, "--expires", EXPIRES, "--backend", "github", "--gh-repository",
                "TEST-owner/TEST-mirror", "--gh-tag", "bundle-1", "--gh-staging", str(mirror),
                "--gh-dry-run", "--gh-calls", str(calls)]
        with patch("subprocess.run", side_effect=AssertionError("no gh")):
            self.assertEqual(publish.main(args), 0)
        self.assertTrue(json.loads(calls.read_text()))
        self.assertEqual((mirror / "layout/channels/stable.json").read_bytes(), self.source["channels/stable.json"])

    def test_republish_uses_adapter_without_rebuilding_blobs(self):
        self.service.publish(self.body, self.blobs)
        republish.republish(self.service.repo, 1, 2, signer=self.service.signer("TEST-release-1"),
                            pins_bytes=self.service.pins, channel="stable", issued=ISSUED, expires=EXPIRES,
                            created=ISSUED, backend=self.backend)
        self.assertEqual(verify(self.service, self.store.data)["bundle_version"], 2)
        self.assertEqual({k: v for k, v in self.store.data.items() if k.startswith("blobs/")},
                         {k: v for k, v in self.source.items() if k.startswith("blobs/")})


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.service = Service(self)
        body, blobs = self.service.build_and_publish()
        self.source = self.service.snapshot()
        raw = self.source["bundles/1.json"]
        self.objects = backends.release_objects(self.service.repo, body, blobs, raw,
            self.source["channels/stable.json"], publish.load_trust(self.service.repo, self.service.pins)[1], ISSUED)
        self.staging = self.service.dir / "mirror"

    def backend(self):
        return GitHubBackend("TEST-owner/TEST-mirror", "bundle-1", self.staging, dry_run=True,
                             calls_file=self.service.dir / "calls.json")

    def test_dry_run_exact_commands_order_and_identical_verifier_output(self):
        backend = self.backend()
        with patch("subprocess.run", side_effect=AssertionError("must not execute gh")):
            backend.publish(self.objects)
        repo = ["--repo", "TEST-owner/TEST-mirror"]
        expected = [["gh", "release", "view", "bundle-1", "--json", "assets,isDraft", *repo],
                    ["gh", "release", "create", "bundle-1", "--draft", "--title", "bundle-1", "--notes",
                     "Signed update-service snapshot", *repo]]
        names = [o.path.replace("/", "--") for o in self.objects]
        names.insert(len(names) - 1, "cache-policy.json")
        downloads = [c for c in backend.calls if c[2] == "download"]
        for name, download in zip(names, downloads):
            expected.append(["gh", "release", "upload", "bundle-1", str(self.staging / "assets" / name), *repo])
            expected.append(["gh", "release", "download", "bundle-1", "--pattern", name, "--dir", download[7], *repo])
        expected.append(["gh", "release", "edit", "bundle-1", "--draft=false", *repo])
        self.assertEqual(backend.calls, expected)
        self.assertEqual(json.loads((self.service.dir / "calls.json").read_text()), expected)
        layout = {str(p.relative_to(self.staging / "layout")): p.read_bytes()
                  for p in (self.staging / "layout").rglob("*") if p.is_file()}
        self.assertEqual(layout, self.source)
        for consumer in (BOX, MAC, IOS):
            self.assertEqual(verify(self.service, layout, consumer), verify(self.service, self.source, consumer))
        self.assertFalse(backend.state["draft"])
        self.assertTrue(all("--clobber" not in c for c in backend.calls))
        policies = json.loads((self.staging / "assets/cache-policy.json").read_text())
        for obj in self.objects:
            self.assertEqual(policies[obj.path.replace("/", "--")]["cache_control"], obj.cache_control)
        # Published tags are idempotent for identical bytes and immutable otherwise.
        again = self.backend()
        self.assertEqual(again.publish(self.objects), [])
        changed = list(self.objects)
        changed[-2] = backends.Object("keys.json", b"different", False)
        with self.assertRaisesRegex(backends.BackendError, "never overwritten"):
            again.publish(changed)

    def test_downloaded_assets_materialize_for_p0b_and_reject_traversal(self):
        self.backend().publish(self.objects)
        output = self.service.dir / "downloaded-layout"
        materialize(self.staging / "assets", output)
        layout = {str(p.relative_to(output)): p.read_bytes() for p in output.rglob("*") if p.is_file()}
        for consumer in (BOX, MAC, IOS):
            self.assertEqual(verify(self.service, layout, consumer), verify(self.service, self.source, consumer))
        policy = self.staging / "assets/cache-policy.json"
        policy.write_text(json.dumps({"evil": {"path": "../escape"}}))
        with self.assertRaisesRegex(backends.BackendError, "unsafe mirror"):
            materialize(self.staging / "assets", self.service.dir / "bad-layout")
        self.assertFalse((self.service.dir / "escape").exists())

    def test_injected_gh_runner_executes_real_branch_without_network(self):
        import subprocess
        state = {"exists": False, "draft": True, "assets": {}}
        def runner(argv, **kwargs):
            action = argv[2]
            if action == "view":
                if not state["exists"]:
                    return subprocess.CompletedProcess(argv, 1, "", "release not found")
                doc = {"isDraft": state["draft"], "assets": [{"name": n} for n in state["assets"]]}
                return subprocess.CompletedProcess(argv, 0, json.dumps(doc), "")
            if action == "create":
                state["exists"] = True
            elif action == "upload":
                path = Path(argv[4])
                self.assertNotIn(path.name, state["assets"])
                state["assets"][path.name] = path.read_bytes()
            elif action == "download":
                (Path(argv[7]) / argv[5]).write_bytes(state["assets"][argv[5]])
            elif action == "edit":
                self.assertIn("channels--stable.json", state["assets"])
                state["draft"] = False
            return subprocess.CompletedProcess(argv, 0, "", "")
        backend = GitHubBackend("TEST-owner/TEST-mirror", "bundle-1", self.staging, runner=runner)
        backend.publish(self.objects)
        self.assertFalse(state["draft"])
        assets = self.service.dir / "downloaded-assets"
        assets.mkdir()
        for name, data in state["assets"].items():
            (assets / name).write_bytes(data)
        output = self.service.dir / "real-layout"
        materialize(assets, output)
        layout = {str(p.relative_to(output)): p.read_bytes() for p in output.rglob("*") if p.is_file()}
        self.assertEqual(layout, self.source)
        self.assertEqual(verify(self.service, layout), verify(self.service, self.source))
        self.assertEqual(backend.publish(self.objects), [])

    def test_both_backends_enforce_order_and_refuse_missing_dependencies(self):
        # Call the backend boundary directly, bypassing the publisher's preparation.
        store = FakeStore()
        backends.ObjectStoreBackend(store).publish(list(reversed(self.objects)))
        self.assertEqual([p for a, p in store.calls if a == "put"][-1], "channels/stable.json")
        mirror = self.backend()
        missing = [o for o in self.objects if not o.path.startswith("blobs/")]
        for backend in (backends.ObjectStoreBackend(FakeStore()), mirror):
            with self.assertRaisesRegex(backends.BackendError, "missing or mismatched blob"):
                backend.publish(missing)
        self.assertEqual(mirror.calls, [])

    def test_auth_failure_does_not_create_a_release(self):
        import subprocess
        from unittest.mock import Mock
        runner = Mock(return_value=subprocess.CompletedProcess([], 1, "", "HTTP 403 forbidden"))
        backend = GitHubBackend("TEST-owner/TEST-mirror", "bundle-1", self.staging, runner=runner)
        with self.assertRaisesRegex(backends.BackendError, "view failed"):
            backend.publish(self.objects)
        self.assertEqual(len(backend.calls), 1)

    def test_failure_at_every_gh_command_keeps_release_draft_or_complete(self):
        # Use a dry-run call boundary, including the final publish operation.
        probe = self.backend()
        probe.publish(self.objects)
        count = len(probe.calls)
        import shutil
        for step in range(1, count + 1):
            with self.subTest(step=step):
                shutil.rmtree(self.staging)
                backend = self.backend()
                original = backend._call
                def fail(*args):
                    if len(backend.calls) + 1 == step:
                        raise OSError("injected gh failure")
                    return original(*args)
                with patch.object(backend, "_call", side_effect=fail):
                    with self.assertRaises(OSError):
                        backend.publish(self.objects)
                self.assertTrue(backend.state["draft"])
                # Resume any partial draft; no upload can overwrite an existing asset.
                resumed = self.backend()
                resumed.publish(self.objects)
                self.assertFalse(resumed.state["draft"])
                layout = {str(p.relative_to(self.staging / "layout")): p.read_bytes()
                          for p in (self.staging / "layout").rglob("*") if p.is_file()}
                assert_closed(self, layout)


class S3RequestTests(unittest.TestCase):
    def client(self, opener):
        return S3Client("https://s3.invalid", "TEST-bucket", "auto", "TEST-access", "TEST-secret",
                        opener=opener, clock=lambda: datetime(2026, 10, 20, tzinfo=timezone.utc))

    def test_sigv4_headers_conditionals_path_and_no_credential_discovery(self):
        from unittest.mock import MagicMock
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.read.return_value = b"data"
        response.headers = {"ETag": '"test-etag"'}
        with patch.dict("os.environ", {"AWS_ACCESS_KEY_ID": "DO-NOT-READ", "AWS_SECRET_ACCESS_KEY": "DO-NOT-READ"}):
            client = self.client(opener)
            client.put("blobs/sha256/test", b"data", cache_control=backends.IMMUTABLE_CACHE,
                       content_type="application/octet-stream", if_none_match=True, if_match=None)
        req = opener.open.call_args.args[0]
        headers = {k.lower(): v for k, v in req.header_items()}
        self.assertEqual(req.full_url, "https://s3.invalid/TEST-bucket/blobs/sha256/test")
        self.assertEqual(headers["if-none-match"], "*")
        self.assertEqual(headers["cache-control"], backends.IMMUTABLE_CACHE)
        self.assertIn("Credential=TEST-access/20261020/auto/s3/aws4_request", headers["authorization"])
        self.assertIn("cache-control;content-type;host;if-none-match;x-amz-content-sha256;x-amz-date", headers["authorization"])
        self.assertEqual(headers["x-amz-content-sha256"], hashlib.sha256(b"data").hexdigest())
        self.assertEqual(client.get("keys.json"), (b"data", '"test-etag"'))
        client.put("channels/stable.json", b"data", cache_control=backends.MUTABLE_CACHE,
                   content_type="application/json", if_none_match=False, if_match='"test-etag"')
        self.assertEqual(opener.open.call_args.args[0].get_header("If-match"), '"test-etag"')

    def test_only_404_means_missing_and_redirects_auth_and_timeouts_fail(self):
        from unittest.mock import MagicMock
        for code in (301, 307, 403, 404, 412, 500):
            opener = MagicMock()
            opener.open.side_effect = HTTPError("https://s3.invalid", code, "test", {}, io.BytesIO())
            if code == 404:
                self.assertIsNone(self.client(opener).get("keys.json"))
            else:
                with self.assertRaises(backends.BackendError):
                    self.client(opener).get("keys.json")
        opener.open.side_effect = TimeoutError("timeout")
        with self.assertRaises(TimeoutError):
            self.client(opener).get("keys.json")

    def test_unsafe_endpoints_and_keys_refused(self):
        for endpoint in ("http://s3.invalid", "https://user:pass@s3.invalid", "https://s3.invalid/path"):
            with self.assertRaises(backends.BackendError):
                S3Client(endpoint, "TEST", "auto", "TEST", "TEST")
        client = self.client(None)
        with self.assertRaises(backends.BackendError):
            client.get("../keys.json")


if __name__ == "__main__":
    unittest.main()
