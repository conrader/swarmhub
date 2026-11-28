BEGIN IMMEDIATE;
-- How much a bot asks the person before acting. NULL follows Auto mode: balanced with Auto on, careful with it off.
ALTER TABLE bot_agent_settings ADD COLUMN autonomy TEXT CHECK(autonomy IN ('careful','balanced','full'));
PRAGMA user_version=90;
COMMIT;
