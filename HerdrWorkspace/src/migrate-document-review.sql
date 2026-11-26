BEGIN IMMEDIATE;
ALTER TABLE bot_agent_settings ADD COLUMN document_read_only INTEGER NOT NULL DEFAULT 0 CHECK(document_read_only IN (0,1));
ALTER TABLE journal ADD COLUMN document_read_only INTEGER NOT NULL DEFAULT 0 CHECK(document_read_only IN (0,1));
PRAGMA user_version=84;
COMMIT;
