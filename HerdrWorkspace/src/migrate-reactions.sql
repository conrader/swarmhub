BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN reaction TEXT CHECK(reaction IN ('like','thanks','celebrate','eyes'));
ALTER TABLE group_messages ADD COLUMN reaction TEXT CHECK(reaction IN ('like','thanks','celebrate','eyes'));
PRAGMA user_version = 24;
COMMIT;
