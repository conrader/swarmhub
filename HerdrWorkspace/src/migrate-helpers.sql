BEGIN IMMEDIATE;
-- A helper is a launch that another managed agent asked for. `launch` is the helper's own launch row,
-- which holds its task and terminal; `parent_key` is the launch key of the agent that started it.
CREATE TABLE helpers (
  launch INTEGER PRIMARY KEY REFERENCES journal(id),
  parent_key TEXT NOT NULL REFERENCES journal(launch_key),
  name TEXT NOT NULL,
  difficulty TEXT NOT NULL CHECK (difficulty IN ('easy', 'medium', 'hard')),
  template TEXT NOT NULL,
  model TEXT NOT NULL
);
CREATE INDEX helpers_by_parent ON helpers(parent_key, launch);
PRAGMA user_version = 47;
COMMIT;
