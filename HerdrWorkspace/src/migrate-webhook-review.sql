BEGIN IMMEDIATE;
CREATE TABLE webhook_reviews (
  id INTEGER PRIMARY KEY,
  routine INTEGER NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  event_key TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  binding TEXT NOT NULL,
  payload TEXT,
  dismissed INTEGER NOT NULL DEFAULT 0 CHECK (dismissed IN (0,1)),
  UNIQUE(routine,event_key)
);
CREATE INDEX webhook_reviews_waiting ON webhook_reviews(routine,id) WHERE dismissed=0;
PRAGMA user_version = 34;
COMMIT;
