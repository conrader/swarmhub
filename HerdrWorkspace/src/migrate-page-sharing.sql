BEGIN IMMEDIATE;
CREATE TABLE page_shares (
  page INTEGER PRIMARY KEY REFERENCES workspace_pages(id) ON DELETE CASCADE,
  link_id TEXT NOT NULL,
  token_digest BLOB UNIQUE NOT NULL CHECK(length(token_digest)=32),
  revision INTEGER NOT NULL,
  title TEXT NOT NULL,
  markdown TEXT NOT NULL,
  follow_latest INTEGER NOT NULL CHECK(follow_latest IN (0,1)),
  expires_ms INTEGER NOT NULL
);
CREATE INDEX page_shares_expiry ON page_shares(expires_ms);
PRAGMA user_version = 46;
COMMIT;
