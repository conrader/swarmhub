BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN usage_thread TEXT;
ALTER TABLE journal ADD COLUMN session_usage TEXT;
PRAGMA user_version = 72;
COMMIT;
