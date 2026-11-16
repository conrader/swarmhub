BEGIN IMMEDIATE;
CREATE TABLE approvals (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,
  tool TEXT NOT NULL,
  requested_ms INTEGER NOT NULL,
  resolved_ms INTEGER,
  state TEXT NOT NULL CHECK(state IN ('pending','approved','denied','terminal'))
);
PRAGMA user_version = 5;
COMMIT;
