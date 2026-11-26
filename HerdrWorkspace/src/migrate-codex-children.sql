BEGIN IMMEDIATE;
CREATE TABLE codex_children (
    launch INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
    thread TEXT NOT NULL,
    summary TEXT NOT NULL,
    transcript TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(launch, thread)
);
PRAGMA user_version=79;
COMMIT;
