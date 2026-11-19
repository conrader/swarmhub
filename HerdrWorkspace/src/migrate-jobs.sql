BEGIN IMMEDIATE;

-- Retain the project ID in the job history even if the project is deleted.
CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  owner_bot_id TEXT NOT NULL REFERENCES bots(id),
  project INTEGER NOT NULL CHECK (project > 0),
  brief TEXT NOT NULL CHECK (length(CAST(brief AS BLOB)) BETWEEN 1 AND 12000),
  workdir TEXT NOT NULL CHECK (length(CAST(workdir AS BLOB)) BETWEEN 1 AND 4096),
  requested_runtime TEXT NOT NULL CHECK (json_valid(requested_runtime)),
  submit_key TEXT NOT NULL CHECK (length(CAST(submit_key AS BLOB)) BETWEEN 1 AND 128),
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  created_ms INTEGER NOT NULL,
  UNIQUE (owner_bot_id, submit_key)
) WITHOUT ROWID;

CREATE TRIGGER jobs_immutable BEFORE UPDATE ON jobs
BEGIN
  SELECT RAISE(ABORT, 'job submission is immutable');
END;

CREATE TABLE job_attempts (
  job_id TEXT NOT NULL REFERENCES jobs(id),
  attempt INTEGER NOT NULL CHECK (attempt > 0),
  status TEXT NOT NULL CHECK (status IN (
    'queued','dispatching','running','exited','cancelled','interrupted','unknown'
  )),
  host_id TEXT,
  lease_id TEXT,
  requested_runtime TEXT NOT NULL CHECK (json_valid(requested_runtime)),
  observed_runtime TEXT CHECK (json_valid(observed_runtime) OR observed_runtime IS NULL),
  observed_cli_version TEXT,
  verdict TEXT CHECK (verdict IN ('succeeded','failed','cancelled','interrupted')),
  exit_code INTEGER,
  exit_reason TEXT CHECK (exit_reason IN (
    'completed','nonzero_exit','missing_result','cancelled','interrupted',
    'start_unconfirmed','exit_unconfirmed'
  )),
  log_ref TEXT,
  result_ref TEXT,
  result_digest TEXT CHECK (length(result_digest) = 64),
  CHECK ((host_id IS NULL) = (lease_id IS NULL)),
  CHECK (status = 'queued' OR status = 'cancelled' OR host_id IS NOT NULL),
  CHECK ((status = 'exited') = (exit_code IS NOT NULL)),
  CHECK ((status IN ('exited','cancelled','interrupted')) = (verdict IS NOT NULL)),
  CHECK ((status IN ('exited','cancelled','interrupted','unknown')) = (exit_reason IS NOT NULL)),
  CHECK ((result_ref IS NULL) = (result_digest IS NULL)),
  CHECK (verdict IS NOT NULL OR (result_ref IS NULL AND log_ref IS NULL)),
  PRIMARY KEY (job_id, attempt)
) WITHOUT ROWID;

-- The terminal facts for an event are read from its frozen attempt row.
CREATE TRIGGER job_attempts_terminal_immutable BEFORE UPDATE ON job_attempts
WHEN OLD.status IN ('exited','cancelled','interrupted')
BEGIN
  SELECT RAISE(ABORT, 'terminal job attempt is immutable');
END;

CREATE TABLE job_completions (
  job_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  owner_bot_id TEXT NOT NULL REFERENCES bots(id),
  expected_next_action TEXT NOT NULL CHECK (expected_next_action IN (
    'review_result','inspect_failure','review_interruption','review_cancellation'
  )),
  created_ms INTEGER NOT NULL,
  PRIMARY KEY (job_id, attempt),
  FOREIGN KEY (job_id, attempt) REFERENCES job_attempts(job_id, attempt)
) WITHOUT ROWID;
CREATE INDEX job_completions_by_owner ON job_completions(owner_bot_id, created_ms, job_id, attempt);

PRAGMA user_version = 53;
COMMIT;
