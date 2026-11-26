BEGIN IMMEDIATE;
CREATE TABLE gemini_children (
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
    UNION ALL SELECT 'opencode', launch,thread,summary,transcript,revision FROM opencode_children
    UNION ALL SELECT 'gemini', launch,thread,summary,transcript,revision FROM gemini_children;
-- A cursor belongs to one running Gemini parent. Saved child activity outlives it.
CREATE TABLE gemini_transcripts (
    launch INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
    session TEXT NOT NULL,
    path TEXT NOT NULL,
    project_hash TEXT NOT NULL,
    offset INTEGER NOT NULL
);
PRAGMA user_version=82;
COMMIT;
