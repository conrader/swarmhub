BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN page_revision INTEGER;
CREATE INDEX journal_page_tasks ON journal(page_id,id DESC) WHERE page_revision IS NOT NULL;
PRAGMA user_version = 16;
COMMIT;
