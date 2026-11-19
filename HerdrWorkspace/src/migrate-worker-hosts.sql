BEGIN IMMEDIATE;

-- Signed fleet policy remains authoritative. These rows preserve the enrollment
-- and the signed readings used with each generation.
CREATE TABLE worker_hosts (
  workspace TEXT NOT NULL,
  policy_generation INTEGER NOT NULL,
  worker_id TEXT NOT NULL CHECK (length(worker_id) BETWEEN 1 AND 64),
  enrollment TEXT NOT NULL CHECK (json_valid(enrollment) AND json_type(enrollment)='object'),
  PRIMARY KEY (workspace, policy_generation, worker_id),
  FOREIGN KEY (workspace, policy_generation) REFERENCES fleet_policy_versions(workspace, generation)
) WITHOUT ROWID;

CREATE TABLE worker_probes (
  workspace TEXT NOT NULL,
  policy_generation INTEGER NOT NULL,
  worker_id TEXT NOT NULL,
  observed_ms INTEGER NOT NULL CHECK (observed_ms > 0),
  received_ms INTEGER NOT NULL CHECK (received_ms >= observed_ms),
  signed_probe TEXT NOT NULL CHECK (json_valid(signed_probe) AND json_type(signed_probe)='object'),
  PRIMARY KEY (workspace, policy_generation, worker_id, observed_ms),
  FOREIGN KEY (workspace, policy_generation, worker_id)
    REFERENCES worker_hosts(workspace, policy_generation, worker_id)
) WITHOUT ROWID;

CREATE INDEX park_decisions_by_nonce
ON park_decisions(json_extract(CASE WHEN json_valid(basis) THEN basis END,'$.nonce_digest'));

PRAGMA user_version = 56;
COMMIT;
