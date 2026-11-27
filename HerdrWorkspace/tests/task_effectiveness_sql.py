"""Grade a reusable reporting query on visible and unseen in-memory SQLite ledgers."""
import hashlib
import random
import sqlite3


SCHEMA = """
CREATE TABLE projects (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE entries (project_id INTEGER, day TEXT, state TEXT, kind TEXT, cents INTEGER);
"""
WINDOW = {"start": "2026-10-01", "end": "2026-11-01"}


def ledger(seed):
    rng = random.Random(seed)
    projects = [(n, f"Project {n}") for n in rng.sample(range(10, 100), 5)]
    entries = []
    for n, _ in projects[:3]:
        for day, state, kind in [
            ("2026-10-01", "posted", "charge"), ("2026-10-31", "posted", "refund"),
            ("2026-09-30", "posted", "charge"), ("2026-11-01", "posted", "charge"),
            ("2026-10-15", "pending", "charge"),
        ]:
            entries.append((n, day, state, kind, rng.randint(10, 999)))
    # Two identical charges are both real. The fourth project only has excluded rows.
    entries.extend([entries[0], (projects[3][0], "2026-10-31", "void", "charge", 9999)])
    rng.shuffle(entries)
    return projects, entries


def fill(db, projects, entries):
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO projects VALUES (?, ?)", projects)
    db.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?)", entries)
    db.commit()


def setup_sql(path, seed):
    db = sqlite3.connect(path / "ledger.sqlite")
    try:
        fill(db, *ledger(seed))
    finally:
        db.close()
    return ("Napisz raport w report.sql jako jedno zapytanie SQLite z parametrami :start i :end. "
            "Dla każdego projektu, również bez operacji, zwróć id i saldo w groszach. "
            "Policz wszystkie zaksięgowane (posted) charge dodatnio, refund ujemnie, "
            "od :start włącznie do :end wyłącznie. Sortuj po id rosnąco. "
            "Przykładowa baza ledger.sqlite musi pozostać bez zmian. Zapytanie ma działać dla dowolnego okresu.",
            {"seed": seed, "input": hashlib.sha256((path / "ledger.sqlite").read_bytes()).hexdigest()})


def matches(sql, seed, window):
    projects, entries = ledger(seed)
    expected = {n: 0 for n, _ in projects}
    for n, day, state, kind, cents in entries:
        if state == "posted" and window["start"] <= day < window["end"]:
            expected[n] += cents if kind == "charge" else -cents
    db = sqlite3.connect(":memory:")
    try:
        fill(db, projects, entries)
        # Only a bounded read-only SELECT against synthetic tables is evaluated.
        enabled = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION}
        if not hasattr(db, "setlimit"):
            raise RuntimeError("the SQL grader requires Python 3.11+ for SQLite evaluation limits")
        db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 65536)
        db.setlimit(sqlite3.SQLITE_LIMIT_VDBE_OP, 5000)
        db.set_authorizer(lambda action, *_: sqlite3.SQLITE_OK if action in enabled else sqlite3.SQLITE_DENY)
        db.set_progress_handler(lambda: 1, 100000)
        result = db.execute(sql, window).fetchmany(len(expected) + 1)
        return result == sorted(expected.items())
    except (sqlite3.Error, ValueError, OverflowError, MemoryError):
        return False
    finally:
        db.close()


def grade_sql(path, truth):
    source, output = path / "ledger.sqlite", path / "report.sql"
    intact = (source.is_file() and not source.is_symlink()
              and hashlib.sha256(source.read_bytes()).hexdigest() == truth["input"])
    sql = (output.read_text(errors="replace") if output.is_file() and not output.is_symlink()
           and output.stat().st_size <= 16384 else "")
    seed = truth["seed"]
    return {"ledger_intact": intact, "sample_result": matches(sql, seed, WINDOW),
            "unseen_result": matches(sql, seed + 1001, WINDOW),
            "different_period": matches(sql, seed + 1002, {"start": "2026-09-30", "end": "2026-10-02"})}
