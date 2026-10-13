#!/usr/bin/env python3
"""Unit tests for hermes-import-grok.py. Synthetic fixtures and a FakeSessionDB only."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("hermes_import_grok", os.path.join(HERE, "hermes-import-grok.py"))
imp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp)

BOT = "abcdef12-0000-4000-8000-000000000001"
GRP = "99999999-0000-4000-8000-000000000009"
SECRET = "ZZ-secret-body-"


class FakeSessionDB:
    def __init__(self, existing=None):
        self.sessions = {e["id"]: e for e in (existing or [])}
        self.deleted = []
        self.calls = []

    def list_sessions_rich(self, **kw):
        return [{"id": s["id"], "title": s.get("title")} for s in self.sessions.values()]

    def import_sessions(self, payload):
        self.calls.append(payload)
        imported = skipped = 0
        for s in payload:
            if s["id"] in self.sessions:
                skipped += 1
            else:
                self.sessions[s["id"]] = s
                imported += 1
        return {"ok": True, "errors": [], "imported": imported, "skipped": skipped}

    def delete_session(self, sid):
        self.deleted.append(sid)
        self.sessions.pop(sid, None)
        return True


def msg(seq, role, ts, text=None, author=None, to=None):
    return {"id": "m%d" % seq, "seq": seq, "role": role, "author": author, "to": to, "timestamp": ts,
            "text": text if text is not None else SECRET + str(seq)}


def bundle(messages, group=False, name="Rapper", profile="grok-rapper", sid=BOT):
    return {"format": "agentapp-bot-bundle/v1", "source_id": sid, "slug": name.lower(), "name": name,
            "profile": None if group else profile, "is_group": group, "messages": messages, "events": []}


class Base(unittest.TestCase):
    B = staticmethod(lambda: bundle([msg(1, "user", "2026-10-13T10:00:00Z"),
                                     msg(2, "assistant", "2026-10-14T10:00:00Z")]))

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, b):
        d = tempfile.mkdtemp(dir=self.tmp)
        with open(os.path.join(d, "bundle.json"), "w") as f:
            json.dump(b, f)
        return d

    def run_main(self, b, *flags, profile="grok-rapper", db=None):
        argv = ["--bundle-dir", self.write(b), "--profile", profile, "--db", "x.db", "--skip-preflight"] + list(flags)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = imp.main(argv, session_db_factory=lambda p: db)
        return code, out.getvalue(), err.getvalue()


class BuildTests(Base):
    def test_warsaw_day_split_near_midnight(self):
        # 21:59:59Z = 23:59:59 CEST (Oct 13); 22:00:00Z = 00:00:00 CEST (Oct 14)
        b = bundle([msg(1, "user", "2026-10-13T21:59:59.000Z"), msg(2, "assistant", "2026-10-13T22:00:00.000Z")])
        sessions, n = imp.build_sessions(b)
        self.assertEqual(n, 2)
        self.assertEqual([s["id"] for s in sessions], ["grok-import-abcdef12-20261013", "grok-import-abcdef12-20261014"])

    def test_float_timestamps_and_started_at(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00.500Z"), msg(2, "assistant", "2026-10-13T10:00:01.250Z")])
        s = imp.build_sessions(b)[0][0]
        self.assertTrue(all(type(m["timestamp"]) is float for m in s["messages"]))
        self.assertEqual(s["messages"][0]["timestamp"], 1791885600.5)
        self.assertEqual(s["started_at"], 1791885600.5)
        self.assertIs(type(s["started_at"]), float)
        for k in ("ended_at", "archived", "hidden", "pinned", "parent_session_id", "message_count"):
            self.assertNotIn(k, s)
        self.assertEqual(s["source"], "grok-import")

    def test_id_title_format_and_uniqueness(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00Z"), msg(2, "user", "2026-10-14T10:00:00Z")])
        sessions = imp.build_sessions(b)[0]
        self.assertEqual(sessions[0]["title"], "Grok archive · Rapper · 2026-10-13")
        self.assertEqual(len({s["id"] for s in sessions}), 2)
        self.assertEqual(len({s["title"] for s in sessions}), 2)

    def test_skips_system_and_events(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00Z"), msg(2, "system", "2026-10-13T10:00:01Z"),
                    msg(3, "unknown", "2026-10-13T10:00:02Z"), msg(4, "assistant", "2026-10-13T10:00:03Z")])
        b["events"] = [{"id": "e", "seq": 9}]
        s, n = imp.build_sessions(b)
        self.assertEqual(n, 2)
        self.assertEqual([m["role"] for m in s[0]["messages"]], ["user", "assistant"])

    def test_seq_order_kept_despite_timestamp_inversion(self):
        b = bundle([msg(2, "assistant", "2026-10-13T10:00:00Z", "second"), msg(1, "user", "2026-10-13T10:00:05Z", "first")])
        s = imp.build_sessions(b)[0][0]
        self.assertEqual([m["content"] for m in s["messages"]], ["first", "second"])

    def test_cross_bot_prefix(self):
        b = bundle([msg(1, "assistant", "2026-10-13T10:00:00Z", "hi", author="Jarvis", to="Rapper"),
                    msg(2, "assistant", "2026-10-13T10:00:01Z", "own", author="Rapper")])
        m = imp.build_sessions(b)[0][0]["messages"]
        self.assertEqual(m[0]["content"], "[Jarvis → Rapper] hi")
        self.assertEqual(m[0]["role"], "assistant")
        self.assertEqual(m[1]["content"], "own")

    def test_group_prefixes_and_ids(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00Z", "a"), msg(2, "assistant", "2026-10-13T10:00:01Z", "b", author="DMT"),
                    msg(3, "assistant", "2026-10-13T10:00:02Z", "c", author="Achilles")], group=True, name="Trio", sid=GRP)
        s = imp.build_sessions(b)[0][0]
        self.assertEqual(s["id"], "grok-import-group-99999999-20261013")
        self.assertEqual(s["title"], "Grok archive · Group (Trio) · 2026-10-13")
        self.assertEqual([m["content"] for m in s["messages"]], ["[Konrad] a", "[DMT] b", "[Achilles] c"])


class MainTests(Base):
    def test_dry_run_prints_no_content(self):
        code, out, err = self.run_main(self.B(), "--dry-run")
        self.assertEqual(code, 0)
        self.assertNotIn(SECRET, out + err)
        self.assertIn("importable_messages=2", out)

    def test_apply_and_idempotent_rerun(self):
        db = FakeSessionDB()
        self.assertEqual(self.run_main(self.B(), "--apply", db=db)[0], 0)
        self.assertEqual(len(db.sessions), 2)
        code, out, _ = self.run_main(self.B(), "--apply", db=db)
        self.assertEqual(code, 0)
        self.assertIn("imported=0 skipped=2", out)
        self.assertEqual(len(db.sessions), 2)

    def test_partial_existing_skipped(self):
        db = FakeSessionDB([{"id": "grok-import-abcdef12-20261013", "title": "Grok archive · Rapper · 2026-10-13"}])
        code, out, _ = self.run_main(self.B(), "--apply", db=db)
        self.assertEqual(code, 0)
        self.assertIn("imported=1 skipped=1", out)

    def test_duplicate_title_guard(self):
        db = FakeSessionDB([{"id": "other-id", "title": "Grok archive · Rapper · 2026-10-13"}])
        code, _, err = self.run_main(self.B(), "--apply", db=db)
        self.assertEqual(code, 1)
        self.assertIn("title already used", err)
        self.assertEqual(db.calls, [])

    def test_import_exception_is_caught(self):
        db = FakeSessionDB()
        def boom(payload):
            raise RuntimeError("IntegrityError")
        db.import_sessions = boom
        self.assertEqual(self.run_main(self.B(), "--apply", db=db)[0], 1)

    def test_group_into_two_profiles(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00Z")], group=True, name="Trio", sid=GRP)
        dbs = {"grok-dmt": FakeSessionDB(), "grok-achilles": FakeSessionDB()}
        for prof, db in dbs.items():
            self.assertEqual(self.run_main(b, "--apply", profile=prof, db=db)[0], 0)
        a, c = (list(d.sessions) for d in dbs.values())
        self.assertEqual(a, c)
        self.assertEqual(a, ["grok-import-group-99999999-20261013"])

    def test_profile_mismatch_fails(self):
        self.assertEqual(self.run_main(self.B(), "--dry-run", profile="grok-other")[0], 1)

    def test_rollback_only_grok_import_ids(self):
        db = FakeSessionDB([{"id": "grok-import-abcdef12-20261013"}, {"id": "grok-import-group-99999999-20261013"},
                            {"id": "live-session"}])
        code, out, _ = self.run_main(self.B(), "--rollback", db=db)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(db.deleted), ["grok-import-abcdef12-20261013", "grok-import-group-99999999-20261013"])
        self.assertIn("live-session", db.sessions)

    def test_expect_count(self):
        self.assertEqual(self.run_main(self.B(), "--dry-run", "--expect-count", "2")[0], 0)
        code, _, err = self.run_main(self.B(), "--dry-run", "--expect-count", "3")
        self.assertNotEqual(code, 0)
        self.assertIn("mismatch", err)


class HardeningTests(Base):
    def test_hermes_schema_version_reads_table_not_pragma(self):
        import sqlite3
        path = os.path.join(self.tmp, "s.db")
        con = sqlite3.connect(path)
        con.execute("CREATE TABLE schema_version (version INTEGER)")
        con.execute("INSERT INTO schema_version VALUES (31)")
        con.commit()
        pragma = con.execute("PRAGMA schema_version").fetchone()[0]
        con.close()
        self.assertEqual(imp.hermes_schema_version(path), 31)
        self.assertNotEqual(pragma, 31)  # the PRAGMA counter is NOT the Hermes version

    def test_title_over_100_fails(self):
        b = bundle([msg(1, "user", "2026-10-13T10:00:00Z")], name="X" * 120)
        with self.assertRaises(imp.ImportError_):
            imp.build_sessions(b)

    def test_timestamp_carry_forward(self):
        b = bundle([msg(1, "user", None, "a"), msg(2, "assistant", "2026-10-13T10:00:05Z", "b"),
                    msg(3, "user", None, "c")])
        ts = [m["timestamp"] for m in imp.build_sessions(b)[0][0]["messages"]]
        self.assertEqual(ts[0], ts[1])  # leading untimed -> first valid
        self.assertEqual(ts[2], ts[1])  # trailing untimed -> predecessor

    def test_no_usable_timestamp_fails(self):
        with self.assertRaises(imp.ImportError_):
            imp.build_sessions(bundle([msg(1, "user", None, "a")]))

    def test_naive_timestamp_treated_as_utc(self):
        self.assertEqual(imp.parse_ts("2026-10-13T10:00:00"), imp.parse_ts("2026-10-13T10:00:00Z"))

    def test_rollback_incomplete_fails(self):
        db = FakeSessionDB([{"id": "grok-import-abcdef12-20261013"}])
        db.delete_session = lambda sid: False
        code, _, err = self.run_main(self.B(), "--rollback", db=db)
        self.assertEqual(code, 1)
        self.assertIn("incomplete", err)

    def test_import_not_ok_fails(self):
        db = FakeSessionDB()
        db.import_sessions = lambda payload: {"ok": False, "errors": ["boom"], "imported": 0, "skipped": 0}
        self.assertEqual(self.run_main(self.B(), "--apply", db=db)[0], 1)


if __name__ == "__main__":
    unittest.main()
