BEGIN IMMEDIATE;
ALTER TABLE routine_runs ADD COLUMN task_id INTEGER REFERENCES journal(id);
ALTER TABLE routine_runs ADD COLUMN result_token TEXT;
ALTER TABLE routine_runs ADD COLUMN result_id INTEGER REFERENCES journal(id);
ALTER TABLE routine_runs ADD COLUMN result_state TEXT CHECK(result_state IN ('succeeded','failed'));
CREATE UNIQUE INDEX routine_runs_result_token ON routine_runs(result_token) WHERE result_token IS NOT NULL;
PRAGMA user_version = 30;
COMMIT;
