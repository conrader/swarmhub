BEGIN IMMEDIATE;
CREATE TABLE vault_requests (
  id TEXT PRIMARY KEY,
  launch INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
  name TEXT NOT NULL COLLATE NOCASE,
  label TEXT NOT NULL,
  description TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending','approved','cancelled','used')),
  expires_ms INTEGER NOT NULL,
  entry_id TEXT,
  entry_revision INTEGER,
  UNIQUE(launch, name)
) WITHOUT ROWID;
CREATE INDEX vault_requests_state ON vault_requests(state, expires_ms);
CREATE TABLE vault_keychain_retirements (account TEXT PRIMARY KEY) WITHOUT ROWID;
PRAGMA user_version = 51;
COMMIT;
