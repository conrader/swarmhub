BEGIN IMMEDIATE;
CREATE TABLE group_handoffs (
    message INTEGER PRIMARY KEY REFERENCES group_messages(id) ON DELETE CASCADE,
    address TEXT NOT NULL,
    created_ms INTEGER NOT NULL,
    launch_key TEXT NOT NULL,
    recipient TEXT NOT NULL,
    task TEXT,
    CHECK(task IS NULL OR length(task)>0)
);
CREATE TABLE group_handoff_dispatches (
    proposal INTEGER PRIMARY KEY REFERENCES group_handoffs(message) ON DELETE CASCADE,
    sent_message INTEGER NOT NULL UNIQUE REFERENCES group_messages(id) ON DELETE CASCADE
);
PRAGMA user_version = 43;
COMMIT;
