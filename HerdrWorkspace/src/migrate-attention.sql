BEGIN IMMEDIATE;
CREATE INDEX group_questions_by_id ON group_messages(id DESC) WHERE is_question=1 AND author IS NOT NULL;
PRAGMA user_version = 17;
COMMIT;
