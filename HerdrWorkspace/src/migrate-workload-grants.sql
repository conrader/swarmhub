BEGIN IMMEDIATE;

CREATE TABLE vault_workload_grants (
  id TEXT PRIMARY KEY CHECK (length(id)=32),
  park_id TEXT NOT NULL UNIQUE REFERENCES parks(id),
  park_manifest_digest TEXT NOT NULL CHECK (length(park_manifest_digest)=64),
  job_id TEXT NOT NULL,
  attempt INTEGER NOT NULL CHECK (attempt > 0),
  manifest_digest TEXT NOT NULL CHECK (length(manifest_digest)=64),
  host_id TEXT NOT NULL,
  host_fingerprint TEXT NOT NULL,
  command_pin TEXT NOT NULL CHECK (json_valid(command_pin)),
  entry_id TEXT NOT NULL CHECK (length(entry_id)=32),
  entry_revision INTEGER NOT NULL CHECK (entry_revision > 0),
  approver TEXT NOT NULL CHECK (length(approver)=64),
  workspace TEXT NOT NULL,
  consent_nonce TEXT NOT NULL,
  not_before_ms INTEGER NOT NULL CHECK (not_before_ms >= 0),
  expires_ms INTEGER NOT NULL CHECK (expires_ms > not_before_ms),
  use_limit INTEGER NOT NULL CHECK (use_limit BETWEEN 1 AND 32),
  disposition TEXT NOT NULL DEFAULT 'authorized' CHECK (disposition IN ('authorized','revoked')),
  UNIQUE (workspace, consent_nonce),
  FOREIGN KEY (job_id,attempt) REFERENCES job_attempts(job_id,attempt)
) WITHOUT ROWID;

CREATE TRIGGER workload_grant_no_replace BEFORE INSERT ON vault_workload_grants
WHEN EXISTS (SELECT 1 FROM vault_workload_grants
  WHERE id=NEW.id OR park_id=NEW.park_id OR (workspace=NEW.workspace AND consent_nonce=NEW.consent_nonce))
BEGIN SELECT RAISE(ABORT, 'workload consent is immutable'); END;

CREATE TRIGGER workload_grant_immutable BEFORE UPDATE OF id,park_id,park_manifest_digest,job_id,attempt,
  manifest_digest,host_id,host_fingerprint,command_pin,entry_id,entry_revision,approver,workspace,
  consent_nonce,not_before_ms,expires_ms,use_limit ON vault_workload_grants
BEGIN SELECT RAISE(ABORT, 'workload consent is immutable'); END;

CREATE TRIGGER workload_grant_revoke_only BEFORE UPDATE OF disposition ON vault_workload_grants
WHEN OLD.disposition!='authorized' OR NEW.disposition!='revoked'
BEGIN SELECT RAISE(ABORT, 'workload consent cannot be restored'); END;

CREATE TRIGGER workload_grant_no_delete BEFORE DELETE ON vault_workload_grants
BEGIN SELECT RAISE(ABORT, 'workload consent is immutable'); END;

CREATE TRIGGER workload_grant_revoke_park AFTER UPDATE OF state ON parks
WHEN NEW.state IN ('held','denied','superseded')
BEGIN
  UPDATE vault_workload_grants SET disposition='revoked' WHERE park_id=NEW.id AND disposition='authorized';
END;

PRAGMA user_version = 58;
COMMIT;
