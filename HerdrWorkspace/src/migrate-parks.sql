BEGIN IMMEDIATE;
CREATE TABLE parks (
  id TEXT PRIMARY KEY,
  manifest_digest TEXT NOT NULL,
  manifest TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN (
    'pending','held','denied','superseded','executing','verified','failed','reconciliation'
  )),
  supersedes TEXT UNIQUE REFERENCES parks(id),
  created_ms INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TRIGGER parks_immutable_manifest
BEFORE UPDATE OF id, manifest_digest, manifest, supersedes ON parks
BEGIN
  SELECT RAISE(ABORT, 'park manifest is immutable');
END;
CREATE TABLE park_decisions (
  id INTEGER PRIMARY KEY,
  park_id TEXT NOT NULL REFERENCES parks(id),
  action TEXT NOT NULL CHECK (action IN ('hold','release','deny','supersede','claim')),
  actor TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('human','judge','backstop')),
  basis TEXT NOT NULL,
  classifier_output TEXT,
  policy_version TEXT,
  at_ms INTEGER NOT NULL
);
CREATE INDEX park_decisions_by_park ON park_decisions(park_id, id);
CREATE TABLE park_executions (
  park_id TEXT PRIMARY KEY REFERENCES parks(id),
  attempt TEXT NOT NULL UNIQUE,
  claimed_ms INTEGER NOT NULL,
  observed_before TEXT,
  apply_step TEXT,
  rollback_intent TEXT,
  receipt TEXT
) WITHOUT ROWID;
PRAGMA user_version = 52;
COMMIT;
