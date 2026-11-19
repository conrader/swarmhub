BEGIN IMMEDIATE;

CREATE TABLE outbound_approval_revocations (
  approval_id INTEGER PRIMARY KEY REFERENCES outbound_approvals(id),
  hold_decision_id INTEGER NOT NULL REFERENCES park_decisions(id)
) WITHOUT ROWID;

-- v59 did not store an ordering between approval and Hold records.
INSERT INTO outbound_approval_revocations
SELECT a.id, min(p.id)
FROM outbound_approvals a JOIN park_decisions p
  ON p.park_id=a.park_id AND p.action='hold'
GROUP BY a.id;

CREATE TRIGGER outbound_revocations_no_delete BEFORE DELETE ON outbound_approval_revocations
BEGIN SELECT RAISE(ABORT, 'outbound approval revocation is immutable'); END;
CREATE TRIGGER outbound_revocations_no_update BEFORE UPDATE ON outbound_approval_revocations
BEGIN SELECT RAISE(ABORT, 'outbound approval revocation is immutable'); END;

ALTER TABLE job_review_closures ADD COLUMN operator_decision TEXT
  CHECK(operator_decision IS NULL OR json_valid(operator_decision));
CREATE UNIQUE INDEX job_review_operator_nonce ON job_review_closures(
  json_extract(operator_decision,'$.envelope.workspace'),
  json_extract(operator_decision,'$.envelope.nonce')
) WHERE operator_decision IS NOT NULL;

CREATE TABLE outbound_receipts (
  park_id TEXT PRIMARY KEY REFERENCES outbound_versions(park_id),
  draft_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  attempt TEXT NOT NULL UNIQUE REFERENCES park_executions(attempt),
  payload_digest TEXT NOT NULL CHECK(length(payload_digest)=64),
  message_id TEXT NOT NULL UNIQUE,
  provider_account TEXT NOT NULL,
  approval_id INTEGER NOT NULL REFERENCES outbound_approvals(id),
  provider_id TEXT,
  status TEXT NOT NULL CHECK(status IN ('submitting','reconciliation','not_submitted','accepted')),
  reserved_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL,
  accepted_ms INTEGER,
  UNIQUE(draft_id, version),
  FOREIGN KEY(draft_id, version) REFERENCES outbound_versions(draft_id, version),
  CHECK((status='accepted' AND provider_id IS NOT NULL AND accepted_ms IS NOT NULL)
     OR (status!='accepted' AND provider_id IS NULL AND accepted_ms IS NULL))
) WITHOUT ROWID;

CREATE TRIGGER outbound_receipts_immutable_binding
BEFORE UPDATE OF park_id,draft_id,version,attempt,payload_digest,message_id,provider_account,reserved_ms
ON outbound_receipts BEGIN SELECT RAISE(ABORT, 'outbound reservation is immutable'); END;
CREATE TRIGGER outbound_receipts_accepted_immutable BEFORE UPDATE ON outbound_receipts
WHEN OLD.status='accepted'
BEGIN SELECT RAISE(ABORT, 'outbound acceptance is immutable'); END;
CREATE TRIGGER outbound_receipts_no_delete BEFORE DELETE ON outbound_receipts
BEGIN SELECT RAISE(ABORT, 'outbound reservation is immutable'); END;
CREATE TRIGGER outbound_receipts_no_replace BEFORE INSERT ON outbound_receipts
WHEN EXISTS (SELECT 1 FROM outbound_receipts WHERE park_id=NEW.park_id OR attempt=NEW.attempt
    OR message_id=NEW.message_id OR (draft_id=NEW.draft_id AND version=NEW.version))
BEGIN SELECT RAISE(ABORT, 'outbound reservation is immutable'); END;

PRAGMA user_version = 60;
COMMIT;
