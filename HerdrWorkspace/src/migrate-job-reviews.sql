BEGIN IMMEDIATE;

CREATE TABLE job_review_lineages (
  id TEXT PRIMARY KEY REFERENCES jobs(id),
  owner_bot_id TEXT NOT NULL,
  project INTEGER NOT NULL,
  action TEXT NOT NULL CHECK (action='advance_staging_ref')
) WITHOUT ROWID;

CREATE TABLE job_review_rounds (
  lineage TEXT NOT NULL REFERENCES job_review_lineages(id),
  round INTEGER NOT NULL CHECK (round >= 0),
  producer_job TEXT NOT NULL UNIQUE REFERENCES jobs(id),
  workspace TEXT NOT NULL,
  generation INTEGER NOT NULL,
  exception TEXT CHECK (exception IS NULL OR json_valid(exception)),
  CHECK ((round > 2) = (exception IS NOT NULL)),
  PRIMARY KEY (lineage, round),
  FOREIGN KEY (workspace,generation) REFERENCES fleet_policy_versions(workspace,generation)
) WITHOUT ROWID;

CREATE TABLE job_review_evidence (
  lineage TEXT NOT NULL,
  round INTEGER NOT NULL,
  role TEXT NOT NULL CHECK ((role='author' AND round=0) OR (role='fixer' AND round>0) OR role='reviewer'),
  job_id TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  runtime TEXT NOT NULL CHECK (json_valid(runtime)),
  artifact TEXT NOT NULL CHECK (json_valid(artifact)),
  digest TEXT NOT NULL CHECK (length(digest)=64),
  workspace TEXT NOT NULL,
  generation INTEGER NOT NULL,
  exception TEXT CHECK (exception IS NULL OR json_valid(exception)),
  PRIMARY KEY (lineage, round, role),
  UNIQUE (job_id, attempt),
  FOREIGN KEY (lineage,round) REFERENCES job_review_rounds(lineage,round),
  FOREIGN KEY (job_id,attempt) REFERENCES job_attempts(job_id,attempt),
  FOREIGN KEY (workspace,generation) REFERENCES fleet_policy_versions(workspace,generation)
) WITHOUT ROWID;

CREATE TRIGGER review_lineages_no_replace BEFORE INSERT ON job_review_lineages
WHEN EXISTS (SELECT 1 FROM job_review_lineages WHERE id=NEW.id)
BEGIN SELECT RAISE(ABORT, 'review lineage is immutable'); END;
CREATE TRIGGER review_rounds_no_replace BEFORE INSERT ON job_review_rounds
WHEN EXISTS (SELECT 1 FROM job_review_rounds
  WHERE (lineage=NEW.lineage AND round=NEW.round) OR producer_job=NEW.producer_job)
BEGIN SELECT RAISE(ABORT, 'review round is immutable'); END;
CREATE TRIGGER review_evidence_no_replace BEFORE INSERT ON job_review_evidence
WHEN EXISTS (SELECT 1 FROM job_review_evidence
  WHERE (lineage=NEW.lineage AND round=NEW.round AND role=NEW.role)
    OR (job_id=NEW.job_id AND attempt=NEW.attempt))
BEGIN SELECT RAISE(ABORT, 'review evidence is immutable'); END;

CREATE TRIGGER review_lineages_no_update BEFORE UPDATE ON job_review_lineages
BEGIN SELECT RAISE(ABORT, 'review lineage is immutable'); END;
CREATE TRIGGER review_lineages_no_delete BEFORE DELETE ON job_review_lineages
BEGIN SELECT RAISE(ABORT, 'review lineage is immutable'); END;
CREATE TRIGGER review_rounds_no_update BEFORE UPDATE ON job_review_rounds
BEGIN SELECT RAISE(ABORT, 'review round is immutable'); END;
CREATE TRIGGER review_rounds_no_delete BEFORE DELETE ON job_review_rounds
BEGIN SELECT RAISE(ABORT, 'review round is immutable'); END;
CREATE TRIGGER review_evidence_no_update BEFORE UPDATE ON job_review_evidence
BEGIN SELECT RAISE(ABORT, 'review evidence is immutable'); END;
CREATE TRIGGER review_evidence_no_delete BEFORE DELETE ON job_review_evidence
BEGIN SELECT RAISE(ABORT, 'review evidence is immutable'); END;
CREATE TRIGGER parks_no_replace BEFORE INSERT ON parks
WHEN EXISTS (SELECT 1 FROM parks WHERE id=NEW.id OR supersedes=NEW.supersedes)
BEGIN SELECT RAISE(ABORT, 'park is immutable'); END;
CREATE TRIGGER park_decisions_no_replace BEFORE INSERT ON park_decisions
WHEN EXISTS (SELECT 1 FROM park_decisions WHERE id=NEW.id)
BEGIN SELECT RAISE(ABORT, 'park decision is immutable'); END;
CREATE TRIGGER parks_no_delete BEFORE DELETE ON parks
BEGIN SELECT RAISE(ABORT, 'park is immutable'); END;
CREATE TRIGGER park_decisions_no_delete BEFORE DELETE ON park_decisions
BEGIN SELECT RAISE(ABORT, 'park decision is immutable'); END;
CREATE TRIGGER park_decisions_no_update BEFORE UPDATE ON park_decisions
BEGIN SELECT RAISE(ABORT, 'park decision is immutable'); END;

PRAGMA user_version = 57;
COMMIT;
