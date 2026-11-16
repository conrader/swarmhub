BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN launch_runtime TEXT;
PRAGMA user_version = 10;
COMMIT;
