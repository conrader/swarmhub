BEGIN IMMEDIATE;
CREATE TABLE groups (
  id INTEGER PRIMARY KEY, core TEXT NOT NULL, name TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE TABLE group_members (
  group_id INTEGER NOT NULL REFERENCES groups(id),
  address TEXT NOT NULL, created_ms INTEGER NOT NULL, name TEXT NOT NULL, launch_key TEXT NOT NULL,
  PRIMARY KEY(group_id, address, created_ms)
);
CREATE TABLE group_messages (
  id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL REFERENCES groups(id),
  author TEXT, text TEXT NOT NULL, at_ms INTEGER NOT NULL, delivery_id INTEGER UNIQUE
);
CREATE INDEX group_timeline ON group_messages(group_id, id);
CREATE TABLE group_deliveries (
  id INTEGER PRIMARY KEY, message_id INTEGER NOT NULL REFERENCES group_messages(id),
  address TEXT NOT NULL, created_ms INTEGER NOT NULL, name TEXT NOT NULL, launch_key TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE, state TEXT NOT NULL, detail TEXT,
  UNIQUE(message_id, address, created_ms)
);
PRAGMA user_version = 3;
COMMIT;
