BEGIN IMMEDIATE;
CREATE TABLE approval_rule_audit (
  approval_id INTEGER PRIMARY KEY REFERENCES approvals(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('rule','unconfirmed'))
);
PRAGMA user_version=44;
COMMIT;
