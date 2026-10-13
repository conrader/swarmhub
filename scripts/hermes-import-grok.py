#!/usr/bin/env python3
"""Import a Grok export (agentapp-bot-bundle/v1) into ONE Hermes profile's state.db via SessionDB.import_sessions.

--bundle-dir is a copy of the export folder from the Mac: `~/Documents/SwarmHub Grok Export`, or the older
`~/Documents/Torvli Grok Export` when the new one does not exist (exports made before the rename to SwarmHub).

Counts, session ids and titles are printed; message content, tokens and secrets never are.
Run on the box only as the hermes user (see briefs/P9.md). Preflight is skipped by --skip-preflight (tests only).
"""
import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

RELEASE = "/opt/hermes-core/releases/0.20.5"
SRC = RELEASE + "/src"
EXPECT_SOURCE_COMMIT = "fcbd1076a93841fa88855acce810e342a5b78101"
EXPECT_CODE_SCHEMA_VERSION = 26  # the running 0.20.5 code; the DB files are at 31 (see preflight)
ID_PREFIX = "grok-import-"
SOURCE = "grok-import"
FORMAT = "agentapp-bot-bundle/v1"
TZ_NAME = "Europe/Warsaw"
MAX_TITLE = 100
MAX_MSGS_PER_CALL = 10000
MAX_SESSION_BYTES = 5 * 1024 * 1024  # import_sessions per-session JSON limit


class ImportError_(Exception):
    pass


def warsaw_tz():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(TZ_NAME)
    except Exception as exc:  # ZoneInfoNotFoundError, ImportError
        raise ImportError_("cannot load timezone %s (tzdata missing?): %s" % (TZ_NAME, type(exc).__name__))


def parse_ts(value):
    """Bundle ISO-8601 UTC string -> float epoch seconds, or None."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:  # naive -> treat as UTC, never host-local
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).timestamp()


def load_bundle(bundle_dir):
    path = Path(bundle_dir) / "bundle.json"
    if not path.is_file():
        raise ImportError_("no bundle.json in the bundle dir")
    with open(path, encoding="utf-8") as handle:
        bundle = json.load(handle)
    if bundle.get("format") != FORMAT:
        raise ImportError_("unsupported bundle format")
    sid = bundle.get("source_id")
    if not isinstance(sid, str) or len(sid) < 8 or not all(c.isalnum() or c == "-" for c in sid[:8]):
        raise ImportError_("bad source_id")
    return bundle


def message_text(bundle, msg):
    text = msg.get("text") or ""
    author = msg.get("author")
    if bundle.get("is_group"):
        return "[%s] %s" % (author or "Konrad", text)
    if msg["role"] == "assistant" and author and author != bundle.get("name"):
        return "[%s → %s] %s" % (author, msg.get("to") or bundle.get("name"), text)
    return text


def build_sessions(bundle):
    """Returns (sessions, importable_count). One session per Warsaw calendar day, seq order, float timestamps."""
    tz = warsaw_tz()
    id8 = bundle["source_id"][:8]
    group = bool(bundle.get("is_group"))
    rows = [m for m in bundle.get("messages") or [] if m.get("role") in ("user", "assistant")]
    rows.sort(key=lambda m: m.get("seq") or 0)  # tolerate missing/None seq
    stamps = [parse_ts(m.get("timestamp")) for m in rows]
    valid = [t for t in stamps if t is not None]
    if rows and not valid:
        raise ImportError_("no message has a usable timestamp")
    carried = []  # guaranteed-float: an untimed message carries its predecessor's (leading ones the first valid)
    last = valid[0] if valid else 0.0
    for t in stamps:
        if t is not None:
            last = t
        carried.append(last)
    days = {}
    for m, t in zip(rows, carried):
        day = datetime.fromtimestamp(t, tz).strftime("%Y%m%d")
        days.setdefault(day, []).append({"role": m["role"], "content": message_text(bundle, m), "timestamp": float(t)})
    name = bundle.get("name") or "Grok bot"
    sessions = []
    for day in sorted(days):
        msgs = days[day]
        if len(msgs) > MAX_MSGS_PER_CALL:
            raise ImportError_("a day exceeds the per-session message limit")
        dash = "%s-%s-%s" % (day[:4], day[4:6], day[6:])
        label = "Group (%s)" % name if group else name
        title = "Grok archive · %s · %s" % (label, dash)
        if len(title) > MAX_TITLE:
            raise ImportError_("title longer than %d chars" % MAX_TITLE)
        sid = "%s%s%s-%s" % (ID_PREFIX, "group-" if group else "", id8, day)
        session = {"id": sid, "source": SOURCE, "title": title,
                   "started_at": min(m["timestamp"] for m in msgs), "messages": msgs}
        if len(json.dumps(session, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) > MAX_SESSION_BYTES:
            raise ImportError_("session %s exceeds the %d-byte import limit" % (sid, MAX_SESSION_BYTES))
        sessions.append(session)
    titles = [s["title"] for s in sessions]
    if len(set(titles)) != len(titles):
        raise ImportError_("duplicate title in payload")
    return sessions, sum(len(s["messages"]) for s in sessions)


def get_session_db(db_path):
    sys.path.insert(0, SRC)
    import hermes_state
    return hermes_state.SessionDB(db_path=Path(db_path))


def all_sessions(db):
    """Every session in the DB (any source) — for id-exists and title-collision checks."""
    return list(db.list_sessions_rich(limit=1000000, include_archived=True, include_hidden=True))


def list_archive_sessions(db):
    return list(db.list_sessions_rich(source=SOURCE, limit=1000000, include_archived=True, include_hidden=True))


def hermes_schema_version(db_path):
    """Read the Hermes schema_version TABLE (not SQLite's PRAGMA schema_version counter)."""
    import sqlite3
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        row = con.execute("SELECT version FROM schema_version").fetchone()
    finally:
        con.close()
    if not row:
        raise ImportError_("schema_version table is empty")
    return row[0]


def preflight(db_path, profile, hermes_uid=None):
    """Box-only safety checks; not called by unit tests."""
    if hermes_uid is None:
        import pwd
        hermes_uid = pwd.getpwnam("hermes").pw_uid
    if os.geteuid() != hermes_uid:
        raise ImportError_("not running as the hermes user")
    sys.path.insert(0, SRC)
    import hermes_state
    if not os.path.realpath(str(hermes_state.__file__ or "")).startswith(SRC + "/"):
        raise ImportError_("hermes_state is not from the pinned 0.20.5 src")
    try:
        with open(RELEASE + "/SOURCE_COMMIT", encoding="utf-8") as handle:
            commit = handle.read().strip()
    except OSError as exc:
        raise ImportError_("cannot read SOURCE_COMMIT: %s" % type(exc).__name__)
    if commit != EXPECT_SOURCE_COMMIT:
        raise ImportError_("SOURCE_COMMIT %s != pinned 0.20.5" % commit[:12])
    import hermes_state_common
    if hermes_state_common.SCHEMA_VERSION != EXPECT_CODE_SCHEMA_VERSION:
        raise ImportError_("code SCHEMA_VERSION %s != %d" % (
            hermes_state_common.SCHEMA_VERSION, EXPECT_CODE_SCHEMA_VERSION))
    home = os.environ.get("HERMES_HOME", "")
    if not home or not os.path.isdir(home):
        raise ImportError_("HERMES_HOME is not set to an existing profile dir")
    if os.path.basename(os.path.normpath(home)) != profile:
        raise ImportError_("HERMES_HOME dir name != --profile (%s); profile/db/home must agree" % profile)
    if not os.path.isfile(os.path.join(home, "SOUL.md")):
        raise ImportError_("SOUL.md missing in HERMES_HOME (refusing: SessionDB init may reseed it)")
    if os.path.realpath(db_path) != os.path.realpath(os.path.join(home, "state.db")):
        raise ImportError_("--db is not <HERMES_HOME>/state.db")
    if not os.path.isfile(db_path):
        raise ImportError_("db file missing")
    with open(db_path, "rb") as handle:
        if handle.read(16) != b"SQLite format 3\x00":
            raise ImportError_("db header is not SQLite format 3")
    for suffix in ("-wal", "-shm", "-journal"):
        if os.path.exists(db_path + suffix):
            raise ImportError_("sidecar present: " + suffix)
    version = hermes_schema_version(db_path)
    if version != 31:
        raise ImportError_("db schema_version %s != 31" % version)
    if shutil.disk_usage(os.path.dirname(os.path.abspath(db_path))).free <= 1 << 30:
        raise ImportError_("free space <= 1 GB")


def do_apply(db, sessions):
    existing = all_sessions(db)  # all sources, so a title clash with a non-archive session fails before any write
    existing_ids = {row.get("id") for row in existing}
    existing_titles = {row.get("title"): row.get("id") for row in existing}
    clashes = [s["title"] for s in sessions if s["id"] not in existing_ids and s["title"] in existing_titles]
    if clashes:
        raise ImportError_("title already used by another session: %s" % clashes[0])
    imported = skipped = 0
    for s in sessions:
        if s["id"] in existing_ids:
            skipped += 1
            print("skip (exists) %s" % s["id"])
            continue
        if s["title"] in existing_titles:
            raise ImportError_("title already used by another session: %s" % s["title"])
        try:
            res = db.import_sessions([s])
        except Exception as exc:
            raise ImportError_("import_sessions raised %s for %s" % (type(exc).__name__, s["id"]))
        if not res.get("ok") or res.get("errors") or res.get("imported", 0) + res.get("skipped", 0) != 1:
            raise ImportError_("import_sessions not clean for %s (ok=%s errors=%d imported=%s skipped=%s)" % (
                s["id"], res.get("ok"), len(res.get("errors") or []), res.get("imported"), res.get("skipped")))
        imported += res.get("imported", 0)
        skipped += res.get("skipped", 0)
        print("session %s | %s | messages=%d | imported=%s" % (s["id"], s["title"], len(s["messages"]), res.get("imported")))
    print("applied: imported=%d skipped=%d" % (imported, skipped))


def do_rollback(db):
    ids = [r["id"] for r in list_archive_sessions(db) if str(r.get("id", "")).startswith(ID_PREFIX)]
    deleted = 0
    for sid in ids:
        if db.delete_session(sid):
            deleted += 1
            print("deleted %s" % sid)
        else:
            print("WARNING: not deleted (delete_session returned False) %s" % sid)
    print("rolled back: deleted=%d of %d" % (deleted, len(ids)))
    if deleted != len(ids):
        raise ImportError_("rollback incomplete: %d of %d deleted" % (deleted, len(ids)))


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bundle-dir", required=True)
    p.add_argument("--profile", required=True)
    p.add_argument("--db", required=True)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--rollback", action="store_true")
    p.add_argument("--expect-count", type=int)
    p.add_argument("--skip-preflight", action="store_true")
    return p.parse_args(argv)


def main(argv=None, session_db_factory=get_session_db):
    args = parse_args(argv)
    try:
        if not args.dry_run and not args.skip_preflight:
            preflight(args.db, args.profile)
        if args.rollback:
            do_rollback(session_db_factory(args.db))
            return 0
        bundle = load_bundle(args.bundle_dir)
        if not bundle.get("is_group") and bundle.get("profile") != args.profile:
            raise ImportError_("bundle profile does not match --profile")
        sessions, count = build_sessions(bundle)
        print("profile=%s bot=%s group=%s sessions=%d importable_messages=%d" % (
            args.profile, bundle.get("slug"), bool(bundle.get("is_group")), len(sessions), count))
        if args.expect_count is not None and args.expect_count != count:
            raise ImportError_("expect-count mismatch: expected %d, found %d" % (args.expect_count, count))
        if args.dry_run:
            for s in sessions:
                print("would import %s | %s | messages=%d" % (s["id"], s["title"], len(s["messages"])))
            return 0
        do_apply(session_db_factory(args.db), sessions)
        return 0
    except ImportError_ as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
