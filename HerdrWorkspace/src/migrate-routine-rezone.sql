BEGIN;
ALTER TABLE routines ADD COLUMN run_due_after_rezone INTEGER NOT NULL DEFAULT 0;
PRAGMA user_version = 63;
COMMIT;
