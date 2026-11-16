BEGIN IMMEDIATE;
CREATE TABLE vault_key (
  singleton INTEGER PRIMARY KEY CHECK (singleton=1),
  fingerprint BLOB NOT NULL CHECK (length(fingerprint)=32)
);
CREATE TABLE vault_secrets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  revision INTEGER NOT NULL CHECK (revision>=1),
  updated_ms INTEGER NOT NULL,
  nonce BLOB NOT NULL CHECK (length(nonce)=12),
  ciphertext BLOB NOT NULL
) WITHOUT ROWID;
PRAGMA user_version = 35;
COMMIT;
