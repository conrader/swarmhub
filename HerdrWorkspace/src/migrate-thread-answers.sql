BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN thread_reply_token TEXT;
ALTER TABLE journal ADD COLUMN answers_task INTEGER REFERENCES journal(id);
CREATE UNIQUE INDEX journal_thread_token ON journal(thread_reply_token) WHERE thread_reply_token IS NOT NULL;
CREATE UNIQUE INDEX journal_thread_answer ON journal(answers_task) WHERE answers_task IS NOT NULL;
PRAGMA user_version = 27;
COMMIT;
