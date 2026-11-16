BEGIN IMMEDIATE;
CREATE TABLE routine_proposals (
  message INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  launch TEXT NOT NULL REFERENCES journal(launch_key),
  name TEXT NOT NULL,
  task TEXT NOT NULL,
  schedule TEXT NOT NULL,
  fingerprint BLOB NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','saved','dismissed')),
  routine INTEGER REFERENCES routines(id),
  CHECK((state='saved')=(routine IS NOT NULL)),
  UNIQUE(launch,fingerprint)
);
PRAGMA user_version=40;
COMMIT;
