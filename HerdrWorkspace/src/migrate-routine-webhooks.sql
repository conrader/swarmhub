BEGIN IMMEDIATE;
ALTER TABLE routines ADD COLUMN webhook_hash TEXT;
ALTER TABLE routine_runs RENAME TO old_routine_runs;
CREATE TABLE routine_runs (
  id INTEGER PRIMARY KEY, routine INTEGER NOT NULL REFERENCES routines(id),
  kind TEXT NOT NULL CHECK(kind IN ('schedule','test','webhook')), at_ms INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','sent','not_sent','skipped','start_not_observed','unconfirmed')),
  detail TEXT, task_id INTEGER REFERENCES journal(id), result_token TEXT,
  result_id INTEGER REFERENCES journal(id), result_state TEXT CHECK(result_state IN ('succeeded','failed')),
  event_key TEXT
);
INSERT INTO routine_runs (id,routine,kind,at_ms,state,detail,task_id,result_token,result_id,result_state)
SELECT id,routine,kind,at_ms,state,detail,task_id,result_token,result_id,result_state FROM old_routine_runs;
DROP TABLE old_routine_runs;
CREATE INDEX routine_history ON routine_runs(routine,id);
CREATE UNIQUE INDEX routine_runs_result_token ON routine_runs(result_token) WHERE result_token IS NOT NULL;
CREATE UNIQUE INDEX routine_runs_event_key ON routine_runs(routine,event_key) WHERE event_key IS NOT NULL;
CREATE INDEX routine_webhook_rate ON routine_runs(routine,at_ms) WHERE kind='webhook';
PRAGMA user_version = 31;
COMMIT;
