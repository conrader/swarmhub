BEGIN IMMEDIATE;
ALTER TABLE bot_agent_settings ADD COLUMN reviewer_bot_id TEXT;
ALTER TABLE approvals ADD COLUMN reviewer_bot_id TEXT;
ALTER TABLE approvals ADD COLUMN reviewer_name TEXT;
ALTER TABLE approvals ADD COLUMN reviewer_model TEXT;
ALTER TABLE approvals ADD COLUMN assessment TEXT;
PRAGMA user_version=77;
COMMIT;
