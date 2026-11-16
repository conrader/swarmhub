BEGIN IMMEDIATE;
ALTER TABLE group_messages ADD COLUMN is_question INTEGER NOT NULL DEFAULT 0 CHECK (is_question IN (0,1));
ALTER TABLE group_messages ADD COLUMN in_reply_to INTEGER REFERENCES group_messages(id);
CREATE INDEX group_message_answers ON group_messages(in_reply_to,id DESC) WHERE in_reply_to IS NOT NULL;
PRAGMA user_version = 13;
COMMIT;
