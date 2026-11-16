BEGIN IMMEDIATE;
CREATE TABLE skills (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, summary TEXT NOT NULL, instructions TEXT NOT NULL,
  version INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
  updated_ms INTEGER NOT NULL
);
CREATE TABLE disabled_skills (
  skill INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  core TEXT NOT NULL, address TEXT NOT NULL, created_ms INTEGER NOT NULL,
  PRIMARY KEY(skill,core,address,created_ms)
);
PRAGMA user_version = 7;
COMMIT;
