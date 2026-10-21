"""Dotenv syntax regressions; no runtime oracle dependency or live credentials."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from default_connectors_fixtures import helper


class DotenvSyntaxTests(unittest.TestCase):
    def parse(self, text):
        return dict(helper.dotenv_assignments(text))

    def test_bindings_support_dotenv_keys_whitespace_and_bare_names(self):
        self.assertEqual(self.parse("# comment\nexport\tKEY = value # comment\n'quoted key'=yes\n1KEY=also-valid\n"
                                    "BARE_KEY\nKEY=last\nKEY # bare does not unset\n"),
                         {"KEY": "last", "quoted key": "yes", "1KEY": "also-valid"})

    def test_comments_and_multiline_values_work_at_eof_and_with_all_line_endings(self):
        for newline in ("\n", "\r", "\r\n"):
            for quote in ("'", '"'):
                with self.subTest(newline=newline, quote=quote):
                    value = "first" + newline + "# literal" + newline + "OTHER=inside"
                    self.assertEqual(self.parse("KEY=" + quote + value + quote + "# comment"), {"KEY": value})
                    self.assertEqual(self.parse("KEY=" + quote + value + quote + "\t# comment" + newline + "NEXT=after"),
                                     {"KEY": value, "NEXT": "after"})

    def test_quotes_in_multiline_values_decode_once(self):
        self.assertEqual(self.parse('KEY="first\\nline\n\\\"quoted\\\"\\\\end" # done'),
                         {"KEY": 'first\nline\n"quoted"\\end'})
        self.assertEqual(self.parse("KEY='first\\nline\n\\'quoted\\'\\\\end' # done"),
                         {"KEY": "first\\nline\n'quoted'\\end"})

    def test_file_newlines_and_precedence_match_runtime_loading(self):
        with tempfile.TemporaryDirectory(prefix="dotenv-syntax-") as directory:
            root, profile = Path(directory) / "root.env", Path(directory) / "profile.env"
            root.write_bytes(b'KEY="first\r\nsecond" # comment\r\nKEEP=root\r\n')
            profile.write_text("KEY='profile\nvalue'\nBARE\n")
            with patch.dict(helper.os.environ, {"KEEP": "inherited", "BARE": "inherited"}, clear=True):
                self.assertEqual(helper.environment_values([root]),
                                 {"KEY": "first\nsecond", "KEEP": "root", "BARE": "inherited"})
                self.assertEqual(helper.environment_values([root, profile]),
                                 {"KEY": "profile\nvalue", "KEEP": "root", "BARE": "inherited"})
                self.assertEqual(dict(helper.os.environ), {"KEEP": "inherited", "BARE": "inherited"})

    def test_malformed_bindings_raise_only_fixed_text(self):
        for text in ('KEY="synthetic-sentinel\nsecond', "KEY='synthetic-sentinel' trailing",
                     'KEY="synthetic-sentinel"inner"', "KEY=valid\n=synthetic-sentinel",
                     "KEY=valid\nnot an assignment", "'synthetic-sentinel=value"):
            with self.subTest(text=text):
                with self.assertRaisesRegex(ValueError, "^Malformed dotenv binding$"):
                    self.parse(text)


if __name__ == "__main__":
    unittest.main()
