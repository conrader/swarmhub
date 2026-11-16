BEGIN IMMEDIATE;
CREATE TABLE memory_proposals (
  message INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  launch TEXT NOT NULL REFERENCES journal(launch_key),
  text TEXT,
  fingerprint BLOB NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','saved','dismissed')),
  saved_revision INTEGER,
  CHECK((state='pending')=(text IS NOT NULL)),
  CHECK((state='saved')=(saved_revision IS NOT NULL)),
  UNIQUE(launch,fingerprint)
);
PRAGMA user_version=41;
COMMIT;
