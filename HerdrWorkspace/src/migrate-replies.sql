BEGIN IMMEDIATE;
-- Version 0 was unversioned; create an empty old-format table on fresh installs.
CREATE TABLE IF NOT EXISTS journal (
  id INTEGER PRIMARY KEY,
  launch_key TEXT,
  core_id TEXT NOT NULL,
  address TEXT,
  created_ms INTEGER,
  agent TEXT NOT NULL,
  kind TEXT NOT NULL,
  state TEXT NOT NULL,
  text TEXT NOT NULL,
  detail TEXT,
  at_ms INTEGER NOT NULL
);
ALTER TABLE journal RENAME TO journal_v0;

CREATE TABLE journal (
  id INTEGER PRIMARY KEY,
  launch_key TEXT UNIQUE,
  reply_for TEXT REFERENCES journal (launch_key),
  core_id TEXT NOT NULL,
  address TEXT,
  created_ms INTEGER,
  agent TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('task', 'snapshot', 'reply')),
  state TEXT NOT NULL CHECK (state IN (
    'pending', 'sent', 'not_sent', 'start_not_observed', 'unconfirmed', 'saved', 'received'
  )),
  text TEXT NOT NULL,
  detail TEXT,
  at_ms INTEGER NOT NULL
);

INSERT INTO journal (id, launch_key, core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
SELECT id, launch_key, core_id, address, created_ms, agent, kind, state, text, detail, at_ms
FROM journal_v0;
DROP TABLE journal_v0;
CREATE INDEX by_session ON journal (core_id, address, created_ms, id);
CREATE INDEX by_kind ON journal (kind, id);
CREATE INDEX by_reply ON journal (reply_for);
-- A reply can arrive before terminal.run returns. Link it when Core's terminal
-- identity becomes known, including when the bridge recovers a lost launch.
CREATE TRIGGER bind_early_replies AFTER UPDATE OF address ON journal
WHEN NEW.launch_key IS NOT NULL AND OLD.address IS NULL AND NEW.address IS NOT NULL
BEGIN
  UPDATE journal SET address = NEW.address, created_ms = NEW.created_ms
  WHERE reply_for = NEW.launch_key AND address IS NULL;
END;
PRAGMA user_version = 1;
COMMIT;
