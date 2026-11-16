BEGIN IMMEDIATE;
-- A project is a folder on another machine that Herdr Core reaches (`hc machine ls`). `machine` is Core's name
-- for that machine here.
CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  machine TEXT NOT NULL,
  folder TEXT NOT NULL,
  note TEXT NOT NULL DEFAULT '',
  created_ms INTEGER NOT NULL
);
-- The projects the launching client let one agent use, by the agent's launch key. A helper has no rows of its
-- own: it uses those of the agent that started it.
CREATE TABLE agent_projects (
  launch_key TEXT NOT NULL REFERENCES journal(launch_key),
  project INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  PRIMARY KEY (launch_key, project)
) WITHOUT ROWID;
CREATE INDEX agent_projects_by_project ON agent_projects(project);
PRAGMA user_version = 48;
COMMIT;
