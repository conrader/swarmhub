BEGIN IMMEDIATE;
CREATE TABLE claude_children (
    launch INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
    thread TEXT NOT NULL,
    record TEXT NOT NULL,
    summary TEXT NOT NULL,
    transcript TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(launch,thread)
);
CREATE VIEW native_children AS
    SELECT 'codex' AS runtime, launch,thread,summary,transcript,revision FROM codex_children
    UNION ALL
    SELECT 'claude', launch,thread,summary,transcript,revision FROM claude_children;
PRAGMA user_version=80;
COMMIT;
