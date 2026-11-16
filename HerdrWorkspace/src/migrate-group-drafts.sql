BEGIN IMMEDIATE;
ALTER TABLE group_deliveries ADD COLUMN draft_text TEXT;
ALTER TABLE group_deliveries ADD COLUMN draft_ms INTEGER;
CREATE INDEX group_draft_time ON group_deliveries(draft_ms DESC) WHERE draft_ms IS NOT NULL;
PRAGMA user_version = 33;
COMMIT;
