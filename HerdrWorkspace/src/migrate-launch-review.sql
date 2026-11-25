BEGIN IMMEDIATE;
ALTER TABLE bot_agent_settings ADD COLUMN auto_changed_ms INTEGER;
ALTER TABLE journal ADD COLUMN launch_auto INTEGER;
ALTER TABLE journal ADD COLUMN codex_reviewer TEXT;
ALTER TABLE journal ADD COLUMN codex_review_event TEXT;
PRAGMA user_version = 66;
COMMIT;
