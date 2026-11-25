BEGIN IMMEDIATE;
ALTER TABLE routines ADD COLUMN transferred_owner TEXT;
CREATE TABLE routine_transfers (
    token TEXT PRIMARY KEY, routine INTEGER REFERENCES routines(id),
    phase TEXT NOT NULL CHECK(phase IN ('held','staged','installed','suspended','closed')),
    original_state TEXT, original_next INTEGER, binding TEXT
);
CREATE TABLE routine_undo_attempts (
    token TEXT NOT NULL REFERENCES routine_transfers(token), attempt TEXT NOT NULL,
    cancelled INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(token, attempt)
) WITHOUT ROWID;
CREATE TABLE routine_event_receipts (
    routine INTEGER NOT NULL REFERENCES routines(id),
    digest TEXT NOT NULL,
    PRIMARY KEY(routine,digest)
) WITHOUT ROWID;
PRAGMA user_version = 65;
COMMIT;
