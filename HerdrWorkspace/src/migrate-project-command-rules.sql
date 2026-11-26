BEGIN IMMEDIATE;
CREATE TABLE project_command_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    core TEXT NOT NULL,
    bot TEXT NOT NULL,
    agent TEXT NOT NULL,
    provider TEXT NOT NULL,
    cwd TEXT NOT NULL,
    directory_id TEXT NOT NULL,
    command TEXT NOT NULL,
    timeout_ms INTEGER NOT NULL,
    UNIQUE(core, bot, provider, cwd, directory_id, command, timeout_ms)
);
PRAGMA user_version=75;
COMMIT;
