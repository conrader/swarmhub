BEGIN IMMEDIATE;
ALTER TABLE journal RENAME TO journal_v1;
CREATE TABLE journal (
  id INTEGER PRIMARY KEY,
  launch_key TEXT UNIQUE,
  reply_for TEXT REFERENCES journal (launch_key),
  core_id TEXT NOT NULL,
  address TEXT,
  created_ms INTEGER,
  agent TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('task', 'snapshot', 'reply', 'artifact', 'attachment')),
  state TEXT NOT NULL CHECK (state IN (
    'pending', 'sent', 'not_sent', 'start_not_observed', 'unconfirmed', 'saved', 'received'
  )),
  text TEXT NOT NULL,
  detail TEXT,
  at_ms INTEGER NOT NULL
);
INSERT INTO journal (id, launch_key, reply_for, core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
SELECT id, launch_key, reply_for, core_id, address, created_ms, agent, kind, state, text, detail, at_ms
FROM journal_v1;
DROP TABLE journal_v1;
CREATE INDEX by_session ON journal (core_id, address, created_ms, id);
CREATE INDEX by_kind ON journal (kind, id);
CREATE INDEX by_reply ON journal (reply_for);
CREATE TRIGGER bind_early_replies AFTER UPDATE OF address ON journal
WHEN NEW.launch_key IS NOT NULL AND OLD.address IS NULL AND NEW.address IS NOT NULL
BEGIN
  UPDATE journal SET address = NEW.address, created_ms = NEW.created_ms
  WHERE reply_for = NEW.launch_key AND address IS NULL;
END;
CREATE TABLE artifacts (
  id INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  data BLOB NOT NULL
);
PRAGMA user_version = 2;
COMMIT;
