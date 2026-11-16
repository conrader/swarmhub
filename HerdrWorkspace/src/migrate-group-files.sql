BEGIN IMMEDIATE;
CREATE TABLE group_attachments (
    id INTEGER PRIMARY KEY,
    message_id INTEGER NOT NULL REFERENCES group_messages(id),
    name TEXT NOT NULL,
    data BLOB NOT NULL
);
CREATE INDEX group_attachments_by_message ON group_attachments(message_id, id);
PRAGMA user_version = 12;
COMMIT;
