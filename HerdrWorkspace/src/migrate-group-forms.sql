BEGIN IMMEDIATE;
ALTER TABLE group_messages ADD COLUMN form_json TEXT;
PRAGMA user_version = 14;
COMMIT;
