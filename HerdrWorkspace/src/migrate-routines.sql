BEGIN IMMEDIATE;
CREATE TABLE routines (
  id INTEGER PRIMARY KEY, core TEXT NOT NULL, address TEXT NOT NULL, created_ms INTEGER NOT NULL,
  agent TEXT NOT NULL, name TEXT NOT NULL, task TEXT NOT NULL, schedule TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('active','paused','archived')), next_at INTEGER
);
CREATE INDEX due_routines ON routines(state, next_at);
CREATE TABLE routine_runs (
  id INTEGER PRIMARY KEY, routine INTEGER NOT NULL REFERENCES routines(id),
  kind TEXT NOT NULL CHECK(kind IN ('schedule','test')), at_ms INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','sent','not_sent','skipped','start_not_observed','unconfirmed')),
  detail TEXT
);
CREATE INDEX routine_history ON routine_runs(routine, id);
PRAGMA user_version = 4;
COMMIT;
