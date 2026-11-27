BEGIN IMMEDIATE;
ALTER TABLE bot_history ADD COLUMN final_status_work INTEGER REFERENCES bot_work(id);
ALTER TABLE bot_history ADD COLUMN final_status_by TEXT REFERENCES bots(id);
CREATE UNIQUE INDEX bot_history_one_final_status ON bot_history(final_status_work)
  WHERE final_status_work IS NOT NULL;
PRAGMA user_version=87;
COMMIT;
