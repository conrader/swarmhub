BEGIN IMMEDIATE;
ALTER TABLE grok_messages ADD COLUMN attachment_count INTEGER NOT NULL DEFAULT 0;
CREATE TABLE grok_files (
  archive INTEGER NOT NULL REFERENCES grok_imports(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  data BLOB NOT NULL,
  PRIMARY KEY(archive,name)
) WITHOUT ROWID;
CREATE TABLE grok_message_files (
  archive INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY(archive,seq,name),
  FOREIGN KEY(archive,seq) REFERENCES grok_messages(archive,seq) ON DELETE CASCADE,
  FOREIGN KEY(archive,name) REFERENCES grok_files(archive,name) ON DELETE CASCADE
) WITHOUT ROWID;
PRAGMA user_version = 32;
COMMIT;
