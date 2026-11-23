BEGIN IMMEDIATE;
CREATE TABLE bot_agent_settings (
    bot TEXT PRIMARY KEY,
    helper_template TEXT,
    helper_model TEXT,
    auto_mode INTEGER NOT NULL DEFAULT 0,
    CHECK ((helper_template IS NULL) = (helper_model IS NULL))
);
ALTER TABLE journal ADD COLUMN parent_bot_id TEXT;
PRAGMA user_version = 64;
COMMIT;
