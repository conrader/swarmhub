BEGIN IMMEDIATE;

CREATE TABLE outbound_drafts (
  id TEXT PRIMARY KEY CHECK(length(id)=32),
  owner TEXT NOT NULL,
  project TEXT NOT NULL,
  legacy_message INTEGER UNIQUE REFERENCES email_drafts(message)
) WITHOUT ROWID;

CREATE TABLE outbound_versions (
  draft_id TEXT NOT NULL REFERENCES outbound_drafts(id),
  version INTEGER NOT NULL CHECK(version > 0),
  payload TEXT NOT NULL CHECK(json_valid(payload)),
  payload_digest TEXT NOT NULL CHECK(length(payload_digest)=64),
  park_id TEXT NOT NULL UNIQUE REFERENCES parks(id),
  created_ms INTEGER NOT NULL,
  PRIMARY KEY(draft_id, version)
) WITHOUT ROWID;

CREATE TABLE outbound_approvals (
  id INTEGER PRIMARY KEY,
  park_id TEXT NOT NULL REFERENCES outbound_versions(park_id),
  workspace TEXT NOT NULL,
  nonce TEXT NOT NULL,
  signed TEXT NOT NULL CHECK(json_valid(signed)),
  recorded_ms INTEGER NOT NULL,
  UNIQUE(workspace, nonce)
);
CREATE INDEX outbound_approvals_by_park ON outbound_approvals(park_id, id DESC);

CREATE TABLE outbound_text_reviews (
  park_id TEXT PRIMARY KEY REFERENCES outbound_versions(park_id),
  group_id INTEGER NOT NULL REFERENCES groups(id),
  question INTEGER NOT NULL REFERENCES group_messages(id),
  answer INTEGER NOT NULL UNIQUE REFERENCES group_messages(id),
  response TEXT NOT NULL,
  recorded_ms INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TRIGGER outbound_drafts_immutable BEFORE UPDATE ON outbound_drafts
BEGIN SELECT RAISE(ABORT, 'outbound draft scope is immutable'); END;
CREATE TRIGGER outbound_drafts_no_delete BEFORE DELETE ON outbound_drafts
BEGIN SELECT RAISE(ABORT, 'outbound draft scope is immutable'); END;
CREATE TRIGGER outbound_versions_immutable BEFORE UPDATE ON outbound_versions
BEGIN SELECT RAISE(ABORT, 'outbound version is immutable'); END;
CREATE TRIGGER outbound_versions_no_delete BEFORE DELETE ON outbound_versions
BEGIN SELECT RAISE(ABORT, 'outbound version is immutable'); END;
CREATE TRIGGER outbound_approvals_no_replace BEFORE INSERT ON outbound_approvals
WHEN EXISTS (SELECT 1 FROM outbound_approvals WHERE (NEW.id>0 AND id=NEW.id) OR (workspace=NEW.workspace AND nonce=NEW.nonce))
BEGIN SELECT RAISE(ABORT, 'outbound approval is immutable'); END;
CREATE TRIGGER outbound_approvals_immutable BEFORE UPDATE ON outbound_approvals
BEGIN SELECT RAISE(ABORT, 'outbound approval is immutable'); END;
CREATE TRIGGER outbound_approvals_no_delete BEFORE DELETE ON outbound_approvals
BEGIN SELECT RAISE(ABORT, 'outbound approval is immutable'); END;
CREATE TRIGGER outbound_text_reviews_immutable BEFORE UPDATE ON outbound_text_reviews
BEGIN SELECT RAISE(ABORT, 'outbound text review is immutable'); END;
CREATE TRIGGER outbound_text_reviews_no_delete BEFORE DELETE ON outbound_text_reviews
BEGIN SELECT RAISE(ABORT, 'outbound text review is immutable'); END;

CREATE TRIGGER outbound_drafts_no_replace BEFORE INSERT ON outbound_drafts
WHEN EXISTS (SELECT 1 FROM outbound_drafts WHERE id=NEW.id OR legacy_message=NEW.legacy_message)
BEGIN SELECT RAISE(ABORT, 'outbound draft scope is immutable'); END;
CREATE TRIGGER outbound_versions_no_replace BEFORE INSERT ON outbound_versions
WHEN EXISTS (SELECT 1 FROM outbound_versions
  WHERE (draft_id=NEW.draft_id AND version=NEW.version) OR park_id=NEW.park_id)
BEGIN SELECT RAISE(ABORT, 'outbound version is immutable'); END;
CREATE TRIGGER outbound_text_reviews_no_replace BEFORE INSERT ON outbound_text_reviews
WHEN EXISTS (SELECT 1 FROM outbound_text_reviews WHERE park_id=NEW.park_id OR answer=NEW.answer)
BEGIN SELECT RAISE(ABORT, 'outbound text review is immutable'); END;

CREATE TABLE job_review_closures (
  lineage TEXT PRIMARY KEY REFERENCES job_review_lineages(id),
  owner_bot_id TEXT NOT NULL,
  launch TEXT NOT NULL,
  reason TEXT NOT NULL,
  closed_ms INTEGER NOT NULL
) WITHOUT ROWID;
CREATE TRIGGER job_review_closures_no_replace BEFORE INSERT ON job_review_closures
WHEN EXISTS (SELECT 1 FROM job_review_closures WHERE lineage=NEW.lineage)
BEGIN SELECT RAISE(ABORT, 'review closure is immutable'); END;
CREATE TRIGGER job_review_closures_immutable BEFORE UPDATE ON job_review_closures
BEGIN SELECT RAISE(ABORT, 'review closure is immutable'); END;
CREATE TRIGGER job_review_closures_no_delete BEFORE DELETE ON job_review_closures
BEGIN SELECT RAISE(ABORT, 'review closure is immutable'); END;

PRAGMA user_version = 59;
COMMIT;
