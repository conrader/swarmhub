BEGIN IMMEDIATE;
ALTER TABLE bot_agent_settings ADD COLUMN command_reviewer TEXT NOT NULL DEFAULT 'off'
    CHECK(command_reviewer IN ('off','haiku','sonnet','opus'));
PRAGMA user_version = 71;
COMMIT;
