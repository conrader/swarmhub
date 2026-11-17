BEGIN IMMEDIATE;
-- An agent that was started before its first task (`warm`). `launch` is its launch row in the journal, which
-- holds no text and stays out of the conversation until `first_task_ms`, when it took the first message.
-- `instructions` and `hints` (a JSON array) are what a launch with a task would have typed around that task;
-- they go with the first task that reaches the agent instead. `tried_ms` is set just before anything is typed,
-- `delivered_ms` once Core confirmed it, and `ended_ms` when the workspace ended an agent nobody wrote to.
CREATE TABLE warm_launches (
  launch INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
  started_ms INTEGER NOT NULL,
  instructions TEXT NOT NULL,
  hints TEXT NOT NULL,
  first_task_ms INTEGER,
  tried_ms INTEGER,
  delivered_ms INTEGER,
  ended_ms INTEGER
);
PRAGMA user_version = 49;
COMMIT;
