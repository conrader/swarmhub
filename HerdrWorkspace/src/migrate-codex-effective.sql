BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN codex_sandbox TEXT;
ALTER TABLE journal ADD COLUMN codex_policy TEXT;
PRAGMA user_version = 68;
COMMIT;
