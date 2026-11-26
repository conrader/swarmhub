BEGIN IMMEDIATE;
CREATE TABLE opencode_children (
    launch INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
    thread TEXT NOT NULL,
    summary TEXT NOT NULL,
    transcript TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(launch,thread)
);
DROP VIEW native_children;
CREATE VIEW native_children AS
    SELECT 'codex' AS runtime, launch,thread,summary,transcript,revision FROM codex_children
    UNION ALL SELECT 'claude', launch,thread,summary,transcript,revision FROM claude_children
    UNION ALL SELECT 'opencode', launch,thread,summary,transcript,revision FROM opencode_children;
PRAGMA user_version=81;
COMMIT;
