BEGIN IMMEDIATE;
CREATE TABLE skill_proposals (
  message INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  launch TEXT NOT NULL REFERENCES journal(launch_key),
  name TEXT NOT NULL,
  summary TEXT NOT NULL,
  instructions TEXT NOT NULL,
  fingerprint BLOB NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','saved','dismissed')),
  skill INTEGER REFERENCES skills(id),
  UNIQUE(launch,fingerprint)
);
PRAGMA user_version=39;
COMMIT;
