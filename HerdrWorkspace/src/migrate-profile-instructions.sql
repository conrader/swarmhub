BEGIN IMMEDIATE;
ALTER TABLE profiles ADD COLUMN instructions TEXT NOT NULL DEFAULT '';
ALTER TABLE journal ADD COLUMN launch_instructions TEXT;
PRAGMA user_version = 11;
COMMIT;
