BEGIN IMMEDIATE;
-- Bots, the messages between them, planned check-ins and promises (`bots`, docs/bot-communication.md).
-- This adds tables only. No table, row or index that existed before is changed, so a workspace from before this
-- version reads the same journal once `user_version` is set back to 49.

-- The bots the app registered. `id` is the app's own id for the bot; `agent_name` is the name its agent runs
-- under in Herdr Core. `noted_launch` is the launch that was given the workspace's notes for bots.
CREATE TABLE bots (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  agent_name TEXT NOT NULL,
  main INTEGER NOT NULL DEFAULT 0,
  template TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL DEFAULT '',
  projects TEXT NOT NULL DEFAULT '[]',
  may_message INTEGER NOT NULL DEFAULT 1,
  takes_messages INTEGER NOT NULL DEFAULT 1,
  takes_initiative INTEGER NOT NULL DEFAULT 1,
  notifications INTEGER NOT NULL DEFAULT 1,
  noted_launch TEXT,
  read_through INTEGER NOT NULL DEFAULT 0,
  created_ms INTEGER NOT NULL,
  updated_ms INTEGER NOT NULL,
  removed_ms INTEGER
);

-- One piece of work that bots write to each other about. `anchor` is the journal row of the task its first
-- message was sent under (a message of the person, a check-in), so further messages of that turn join it.
-- `chain` is a JSON array of the bots it has passed through, in the order they joined.
CREATE TABLE bot_work (
  id INTEGER PRIMARY KEY,
  started_by TEXT NOT NULL,
  owner TEXT NOT NULL,
  origin TEXT NOT NULL,
  anchor INTEGER,
  chain TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'stopped')),
  started_ms INTEGER NOT NULL,
  ended_ms INTEGER,
  ended_why TEXT
);
CREATE INDEX bot_work_by_anchor ON bot_work(started_by, anchor);

-- Every message between two bots. An ask or a hand-off is `open` until it ends; a hand-off that was accepted
-- is `accepted` until its result is reported. Everything else is `sent`.
CREATE TABLE bot_messages (
  id INTEGER PRIMARY KEY,
  work INTEGER NOT NULL REFERENCES bot_work(id),
  kind TEXT NOT NULL CHECK (kind IN ('ask', 'tell', 'handoff', 'reply', 'accept', 'decline')),
  sender TEXT NOT NULL,
  receiver TEXT NOT NULL,
  text TEXT NOT NULL,
  about INTEGER REFERENCES bot_messages(id),
  state TEXT NOT NULL CHECK (state IN ('open', 'accepted', 'answered', 'declined', 'expired', 'stopped', 'sent')),
  via TEXT NOT NULL DEFAULT 'command',
  sent_ms INTEGER NOT NULL,
  delivered_ms INTEGER,
  deadline_ms INTEGER,
  ended_ms INTEGER
);
CREATE INDEX bot_messages_by_state ON bot_messages(state, deadline_ms);
CREATE INDEX bot_messages_by_work ON bot_messages(work, id);

-- Each bot's history: what its chat shows beside the person's own turns. `message` rows are the messages
-- between bots (one row in each bot's history), `said` what the bot's agent wrote at the end of a turn the
-- workspace started, `notice` a line from the workspace for the person.
CREATE TABLE bot_history (
  id INTEGER PRIMARY KEY,
  bot TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('message', 'said', 'notice')),
  text TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  unread INTEGER NOT NULL DEFAULT 0,
  notify INTEGER NOT NULL DEFAULT 0,
  code TEXT,
  message INTEGER REFERENCES bot_messages(id),
  journal INTEGER,
  checkin INTEGER,
  promise INTEGER
);
CREATE INDEX bot_history_by_bot ON bot_history(bot, id);

-- What the workspace types into a bot's agent, in order. `task` is the journal row of the typed task, which is
-- how a reply is known to answer something the workspace sent and not the person.
CREATE TABLE bot_outbox (
  id INTEGER PRIMARY KEY,
  bot TEXT NOT NULL,
  text TEXT NOT NULL,
  cause TEXT NOT NULL CHECK (cause IN ('message', 'outcome', 'notice', 'checkin', 'promise', 'note')),
  message INTEGER,
  work INTEGER,
  checkin INTEGER,
  promise INTEGER,
  quiet INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'typing', 'typed', 'failed', 'dropped')),
  created_ms INTEGER NOT NULL,
  give_up_ms INTEGER NOT NULL,
  typed_ms INTEGER,
  task INTEGER,
  outcome TEXT,
  detail TEXT
);
CREATE INDEX bot_outbox_by_state ON bot_outbox(state, id);
CREATE UNIQUE INDEX bot_outbox_by_task ON bot_outbox(task) WHERE task IS NOT NULL;

-- A planned check-in. `schedule` is JSON: once, interval or daily. `next_ms` is when it fires next.
CREATE TABLE bot_checkins (
  id INTEGER PRIMARY KEY,
  bot TEXT NOT NULL,
  what TEXT NOT NULL,
  schedule TEXT NOT NULL,
  next_ms INTEGER,
  state TEXT NOT NULL DEFAULT 'planned' CHECK (state IN ('planned', 'done', 'cancelled')),
  planned_by TEXT NOT NULL DEFAULT 'bot',
  created_ms INTEGER NOT NULL,
  last_fired_ms INTEGER,
  last_outcome TEXT,
  fires INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX bot_checkins_due ON bot_checkins(state, next_ms);

-- Something a bot said it will do or report by `due_ms`.
CREATE TABLE bot_promises (
  id INTEGER PRIMARY KEY,
  bot TEXT NOT NULL,
  what TEXT NOT NULL,
  due_ms INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'raised', 'overdue', 'done', 'dropped')),
  created_ms INTEGER NOT NULL,
  raised_ms INTEGER,
  overdue_ms INTEGER,
  closed_ms INTEGER,
  note TEXT
);
CREATE INDEX bot_promises_due ON bot_promises(state, due_ms);

-- Something the main bot is told about, once. `key` keeps one thing from being flagged twice.
CREATE TABLE bot_flags (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  key TEXT NOT NULL UNIQUE,
  text TEXT NOT NULL,
  at_ms INTEGER NOT NULL,
  told_ms INTEGER
);

-- Settings and counters. The cursors start at the newest journal row, so nothing saved before this version
-- is read as a bot's reply or as a helper that stopped.
CREATE TABLE bot_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;
INSERT INTO bot_state (key, value) SELECT 'reply_cursor', coalesce(max(id), 0) FROM journal;
INSERT INTO bot_state (key, value) SELECT 'helper_cursor', coalesce(max(id), 0) FROM journal;
PRAGMA user_version = 50;
COMMIT;
