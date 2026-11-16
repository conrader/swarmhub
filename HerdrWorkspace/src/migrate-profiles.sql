BEGIN IMMEDIATE;
CREATE TABLE profiles (
  id INTEGER PRIMARY KEY,
  runtime_name TEXT NOT NULL,
  name TEXT NOT NULL,
  subtitle TEXT NOT NULL DEFAULT '',
  avatar TEXT NOT NULL DEFAULT 'initial',
  pinned INTEGER NOT NULL DEFAULT 0,
  hidden INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1
);
ALTER TABLE journal ADD COLUMN profile_id INTEGER REFERENCES profiles(id);
ALTER TABLE journal ADD COLUMN launch_template TEXT;
CREATE INDEX profile_launches ON journal(profile_id, id DESC) WHERE launch_key IS NOT NULL;
PRAGMA user_version = 9;
COMMIT;
