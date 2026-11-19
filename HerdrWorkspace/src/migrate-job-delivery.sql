BEGIN IMMEDIATE;

CREATE TABLE job_deliveries (
  job_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  outbox INTEGER NOT NULL UNIQUE REFERENCES bot_outbox(id),
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','offered','uncertain','acknowledged')),
  blocker TEXT,
  retry_ms INTEGER NOT NULL DEFAULT 0,
  fallback_notified INTEGER NOT NULL DEFAULT 0 CHECK (fallback_notified IN (0,1)),
  next_step_token TEXT UNIQUE CHECK (length(next_step_token) = 32),
  acknowledged_ms INTEGER,
  acknowledged_launch INTEGER REFERENCES journal(id),
  CHECK ((state = 'acknowledged') = (next_step_token IS NOT NULL)),
  CHECK ((next_step_token IS NULL) = (acknowledged_ms IS NULL)),
  CHECK ((next_step_token IS NULL) = (acknowledged_launch IS NULL)),
  PRIMARY KEY (job_id, attempt),
  FOREIGN KEY (job_id, attempt) REFERENCES job_completions(job_id, attempt)
) WITHOUT ROWID;

CREATE INDEX job_deliveries_due ON job_deliveries(retry_ms, outbox)
  WHERE state != 'acknowledged';

-- Keep prior task/launch evidence when the same logical event moves to a replacement.
CREATE TABLE job_delivery_offers (
  task INTEGER PRIMARY KEY REFERENCES journal(id),
  outbox INTEGER NOT NULL REFERENCES job_deliveries(outbox),
  launch INTEGER NOT NULL REFERENCES journal(id)
);
CREATE INDEX job_delivery_offers_by_launch ON job_delivery_offers(outbox, launch);

PRAGMA user_version = 54;
COMMIT;
