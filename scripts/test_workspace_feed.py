import hashlib
from importlib.util import module_from_spec, spec_from_file_location
from io import BytesIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

import release_feed

spec = spec_from_file_location("published", Path(__file__).with_name("verify-published-update.py"))
published = module_from_spec(spec)
spec.loader.exec_module(published)
FEED = "https://example.test/latest/download"


def http_error(status):
    return HTTPError(FEED, status, "unavailable", {}, None)


class WorkspaceFeedTests(unittest.TestCase):
    def test_previous_build_is_unknown_only_for_a_missing_appcast(self):
        xml = b'<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>50</s:version></item></channel></rss>'
        with patch.object(release_feed, "urlopen", side_effect=[BytesIO(xml), http_error(404), http_error(503), BytesIO(b"<rss/>")]):
            self.assertEqual(release_feed.previous_build(FEED), "50")
            self.assertIsNone(release_feed.previous_build(FEED))
            with self.assertRaises(HTTPError):
                release_feed.previous_build(FEED)
            with self.assertRaisesRegex(ValueError, "build number"):
                release_feed.previous_build(FEED)

    def test_first_release_without_workspace(self):
        with patch.object(release_feed, "urlopen", side_effect=http_error(404)):
            self.assertIsNone(release_feed.workspace(FEED, allow_missing=True))
            with self.assertRaises(HTTPError):
                release_feed.workspace(FEED)

    def test_errors_never_omit_an_existing_feed(self):
        for error in [http_error(503), URLError("disconnected")]:
            with self.subTest(error=error), patch.object(release_feed, "urlopen", side_effect=error):
                with self.assertRaises(URLError):
                    release_feed.workspace(FEED, allow_missing=True)
        for signature in [http_error(404), BytesIO(b"")]:
            with self.subTest(signature=signature), patch.object(release_feed, "urlopen",
                                                                 side_effect=[BytesIO(b"{}"), signature]):
                with self.assertRaises((HTTPError, ValueError)):
                    release_feed.workspace(FEED, allow_missing=True)

    def test_verify_carried_programs_and_reject_changed_download(self):
        base = "https://github.com/conrader/swarmhub/releases/download/v0.8.15/"
        data = b"workspace"
        asset = dict(name="server", target="aarch64-macos", size=len(data), sha256=hashlib.sha256(data).hexdigest())
        manifest = json.dumps(dict(version="0.2.13", base=base, assets=[asset])).encode()
        with tempfile.TemporaryDirectory() as scratch:
            staged = Path(scratch) / "workspace-manifest.json"
            staged.write_bytes(manifest)
            with patch.object(published, "workspace", return_value=(manifest, b"signature")), \
                    patch.object(published.subprocess, "run") as signature, \
                    patch.object(published, "urlopen", side_effect=[BytesIO(data), BytesIO(b"x" * len(data))]) as fetch:
                published.verify_workspace(FEED, "installed-key", staged)
                self.assertEqual(signature.call_args.args[0][-2:], ["signature", "installed-key"])
                fetch.assert_called_once_with(base + "server", timeout=60)
                with self.assertRaisesRegex(ValueError, "differs"):
                    published.verify_workspace(FEED, "installed-key", staged)
                staged.write_bytes(b"newer release")
                with self.assertRaisesRegex(ValueError, "staged"):
                    published.verify_workspace(FEED, "installed-key", staged)
                self.assertEqual(fetch.call_count, 2)


if __name__ == "__main__":
    unittest.main()
