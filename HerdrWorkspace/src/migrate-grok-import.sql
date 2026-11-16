BEGIN IMMEDIATE;
CREATE TABLE grok_imports (
  id INTEGER PRIMARY KEY,
  source_id TEXT NOT NULL UNIQUE,
  profile INTEGER UNIQUE REFERENCES profiles(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  is_group INTEGER NOT NULL CHECK(is_group IN (0,1)),
  updated_ms INTEGER NOT NULL
);
CREATE TABLE grok_messages (
  archive INTEGER NOT NULL REFERENCES grok_imports(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  source_id TEXT,
  role TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
  author TEXT NOT NULL,
  text TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  PRIMARY KEY(archive,seq),
  UNIQUE(archive,source_id)
) WITHOUT ROWID;
PRAGMA user_version = 22;
COMMIT;
