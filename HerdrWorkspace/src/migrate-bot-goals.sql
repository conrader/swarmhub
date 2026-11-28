BEGIN IMMEDIATE;
-- A goal the workspace keeps stepping for a bot, also while no app is open.
CREATE TABLE bot_goals (
  id INTEGER PRIMARY KEY,
  bot TEXT NOT NULL,
  objective TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','waiting','completed','stopped')),
  pause TEXT CHECK (pause IN ('blocked','stalled','unconfirmed','undelivered','silent')),
  iteration INTEGER NOT NULL DEFAULT 0,
  step_limit INTEGER NOT NULL CHECK (step_limit > 0),
  detail TEXT NOT NULL DEFAULT '',
  best TEXT,
  attempt TEXT,
  outbox INTEGER,
  tries INTEGER NOT NULL DEFAULT 0,
  stalls INTEGER NOT NULL DEFAULT 0,
  seen TEXT NOT NULL DEFAULT '[]',
  created_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL
);
CREATE UNIQUE INDEX bot_goals_active ON bot_goals(bot) WHERE state IN ('queued','running','waiting');
CREATE INDEX bot_goals_by_bot ON bot_goals(bot, id);
ALTER TABLE bot_outbox ADD COLUMN goal INTEGER;
PRAGMA user_version=89;
COMMIT;
