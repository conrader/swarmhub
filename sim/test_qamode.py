"""QA launch-descriptor safety tests; no app or backend responses are simulated."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
from pathlib import Path
import tempfile
import unittest

import run as qa


class EndpointTests(unittest.TestCase):
    def test_checkpoint_hooks_accept_no_arbitrary_parameters(self):
        for op in ["checkpoint", "restart.prepare"]:
            self.assertEqual(qa.validate_step({"op": op}), {"op": op})
            for extra in [{"value": "/tmp/production"}, {"prompt": "marker"}, {"command": "kill"}]:
                with self.subTest(op=op, extra=extra), self.assertRaises(qa.Refused):
                    qa.validate_step(dict(op=op, **extra))

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.token = self.root / "token"
        self.token.write_text("a" * 43)
        self.token.chmod(0o600)
        self.endpoint = self.root / "endpoint.json"
        self.value = dict(schema=qa.SCHEMA, port=49371, token_file=str(self.token), data_directory=str(self.root))
        self.save()

    def save(self):
        self.endpoint.write_text(json.dumps(self.value))
        self.endpoint.chmod(0o600)

    def test_private_app_descriptor_selects_only_numeric_loopback(self):
        self.assertEqual(qa.read_endpoint(self.endpoint), (49371, "a" * 43))

    def test_foreign_token_or_directory_refused(self):
        for changes in [dict(token_file="/tmp/token"), dict(data_directory="/tmp"),
                        dict(token_file="token"), dict(token_file=str(self.root / "other")),
                        dict(token_file=1), dict(data_directory=False), dict(url="http://attacker/")]:
            with self.subTest(changes=changes):
                self.value = dict(schema=qa.SCHEMA, port=49371, token_file=str(self.token), data_directory=str(self.root))
                self.value.update(changes)
                self.save()
                with self.assertRaises(qa.Refused):
                    qa.read_endpoint(self.endpoint)

    def test_bad_protocol_and_port_types_refused(self):
        for port in [True, 80, 65536, 49371.0, "49371"]:
            self.value["port"] = port
            self.save()
            with self.subTest(port=port), self.assertRaises(qa.Refused):
                qa.read_endpoint(self.endpoint)
        self.value["port"] = 49371
        self.value["schema"] = "unknown"
        self.save()
        with self.assertRaises(qa.Refused):
            qa.read_endpoint(self.endpoint)

    def test_public_directory_and_descriptor_refused(self):
        self.root.chmod(0o755)
        with self.assertRaises(qa.Refused):
            qa.read_endpoint(self.endpoint)
        self.root.chmod(0o700)
        self.endpoint.chmod(0o644)
        with self.assertRaises(qa.Refused):
            qa.read_endpoint(self.endpoint)

    def test_symlink_descriptor_and_token_refused(self):
        link = self.root / "link"
        link.symlink_to(self.endpoint)
        with self.assertRaises(OSError):
            qa.read_endpoint(link)
        self.token.unlink()
        self.token.symlink_to(self.endpoint)
        with self.assertRaises(OSError):
            qa.read_endpoint(self.endpoint)

    def test_oversize_descriptor_refused(self):
        self.endpoint.write_text(" " * 4097)
        with self.assertRaises(qa.Refused):
            qa.read_endpoint(self.endpoint)

    def test_missing_fields_refused(self):
        original = self.value.copy()
        for key in original:
            self.value = dict(original)
            del self.value[key]
            self.save()
            with self.subTest(key=key), self.assertRaises(qa.Refused):
                qa.read_endpoint(self.endpoint)


if __name__ == "__main__":
    unittest.main()
