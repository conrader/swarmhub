BEGIN IMMEDIATE;
CREATE TABLE email_drafts (
  message INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  launch TEXT NOT NULL REFERENCES journal(launch_key),
  recipients TEXT,
  subject TEXT,
  body TEXT,
  fingerprint BLOB NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'suggested' CHECK(state IN ('suggested','reviewed','dismissed')),
  CHECK((state='dismissed')=(recipients IS NULL AND subject IS NULL AND body IS NULL)),
  CHECK(state='dismissed' OR (recipients IS NOT NULL AND subject IS NOT NULL AND body IS NOT NULL)),
  UNIQUE(launch,fingerprint)
);
PRAGMA user_version=42;
COMMIT;
