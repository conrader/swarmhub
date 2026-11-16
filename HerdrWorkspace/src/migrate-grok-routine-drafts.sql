BEGIN IMMEDIATE;
CREATE TABLE grok_routine_drafts (
  id INTEGER PRIMARY KEY,
  archive INTEGER NOT NULL REFERENCES grok_imports(id) ON DELETE CASCADE,
  source_id TEXT NOT NULL,
  name TEXT NOT NULL,
  task TEXT NOT NULL,
  schedule TEXT,
  source_hint TEXT,
  routine_id INTEGER REFERENCES routines(id),
  dismissed INTEGER NOT NULL DEFAULT 0 CHECK(dismissed IN (0,1)),
  UNIQUE(archive,source_id)
);
PRAGMA user_version = 23;
COMMIT;
