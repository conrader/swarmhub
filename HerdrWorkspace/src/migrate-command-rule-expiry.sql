BEGIN IMMEDIATE;
ALTER TABLE project_command_rules ADD COLUMN expires_ms INTEGER;
PRAGMA user_version=76;
COMMIT;
