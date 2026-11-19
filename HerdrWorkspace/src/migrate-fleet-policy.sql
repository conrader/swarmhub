BEGIN IMMEDIATE;

-- The operator's protected files are authoritative. This journal is an audit copy.
CREATE TABLE fleet_policy_versions (
  workspace TEXT NOT NULL CHECK (length(workspace) BETWEEN 1 AND 128),
  generation INTEGER NOT NULL CHECK (generation > 0),
  digest TEXT NOT NULL CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  published_ms INTEGER NOT NULL CHECK (published_ms >= 0),
  signed_policy TEXT NOT NULL CHECK (json_valid(signed_policy)),
  PRIMARY KEY (workspace, generation),
  UNIQUE (workspace, digest)
) WITHOUT ROWID;

CREATE TRIGGER fleet_policy_versions_no_replace BEFORE INSERT ON fleet_policy_versions
WHEN EXISTS (
  SELECT 1 FROM fleet_policy_versions
  WHERE workspace=NEW.workspace AND (generation=NEW.generation OR digest=NEW.digest)
)
BEGIN
  SELECT RAISE(ABORT, 'fleet policy audit versions are append-only');
END;

CREATE TRIGGER fleet_policy_versions_no_update BEFORE UPDATE ON fleet_policy_versions
BEGIN
  SELECT RAISE(ABORT, 'fleet policy audit versions are append-only');
END;

CREATE TRIGGER fleet_policy_versions_no_delete BEFORE DELETE ON fleet_policy_versions
BEGIN
  SELECT RAISE(ABORT, 'fleet policy audit versions are append-only');
END;

PRAGMA user_version = 55;
COMMIT;
