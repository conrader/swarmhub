"""Malformed indexes must be reported without breaking mirror fallback (TEST keys, in-memory origins only)."""

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import index, line, manifest, ref_jcs  # noqa: E402
from pull_fixtures import PullCase  # noqa: E402


class MemoryOrigin:
    def __init__(self, url):
        self.url, self.root, self.responses, self.log = url, None, {}, []

    def paths(self):
        return list(self.log)


class MalformedIndex(PullCase):
    def serve(self):
        if not hasattr(self, "services"):
            self.services = {}
        service = MemoryOrigin("https://origin-%d.invalid/" % len(self.services))
        self.services[service.url] = service
        return service

    def pull(self, *origins):
        services = self.services

        class MemoryFetcher:
            def __init__(self, bases, hosts):
                pass

            def get(self, url, limit):
                base, path = url.split("/", 3)[2:]
                service = services["https://" + base + "/"]
                service.log.append(path)
                raw = service.responses[path][1] if path in service.responses else (service.root / path).read_bytes()
                if len(raw) > limit:
                    raise AssertionError("test origin exceeded fetch limit")
                return raw

        return super().pull(*origins, fetcher=MemoryFetcher)

    def test_malformed_indexes_keep_last_good_and_try_the_mirror(self):
        v1, comps = self.start()
        mirror = self.serve()
        mirror.root = self.service.root
        good = json.loads(index([line(manifest(11, [c for c, _ in comps]), 11)], 6))
        bad_signed = [dict(good["signed"], lines=value) for value in
                      (0, None, True, "wrong", {}, [None], [0], ["wrong"], [{}])]
        valid_line = good["signed"]["lines"][0]
        for field, value in (("requires", []), ("requires", {"hermes": 0}),
                             ("bundle_version", "wrong"), ("bundle_version", -1),
                             ("rollout_percent", {}), ("rollout_percent", True)):
            bad_signed.append(dict(good["signed"], lines=[dict(valid_line, **{field: value})]))
        documents = [json.dumps(dict(good, signed=body)).encode() for body in bad_signed]
        documents += [b"not json", b"[]", b"null", b'{"signed":null}',
                      ref_jcs.canonical(dict(good, signed=[]))]
        before = self.runtime()
        for raw in documents:
            with self.subTest(raw=raw[:180]):
                self.service.responses["channels/stable.json"] = (200, raw, {})
                code, out = self.pull(self.service.url)
                self.assertEqual((code, out["last"]["stage"], out["last"]["reason"]),
                                 (65, "index", "schema_invalid"))
                self.assertEqual(out["last"]["lines"], [])
                self.assert_runtime_unchanged(before)
                mirror.log.clear()
                code, out = self.pull(self.service.url, mirror.url)
                self.assertEqual((code, out["state"], out["last"]["origin"]), (0, "current", mirror.url))
                attempt = out["last"]["attempts"][0]
                self.assertEqual((attempt["origin"], attempt["stage"], attempt["reason"], attempt["lines"]),
                                 (self.service.url, "index", "schema_invalid", []))
                self.assertEqual(out["bundle"]["bundle_version"], 11)
                self.assertEqual(mirror.paths(), ["keys.json", "channels/stable.json"])
                self.assert_runtime_unchanged(before)
        self.assert_live(v1)


if __name__ == "__main__":
    unittest.main()
