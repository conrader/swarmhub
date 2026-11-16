BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN event_key TEXT;
CREATE UNIQUE INDEX by_hook_event ON journal(reply_for, event_key) WHERE event_key IS NOT NULL;
ALTER TABLE approvals ADD COLUMN provider TEXT NOT NULL DEFAULT 'Claude Code';
PRAGMA user_version = 6;
COMMIT;
