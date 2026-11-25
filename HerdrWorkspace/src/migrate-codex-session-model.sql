BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN codex_session_model TEXT;
CREATE TABLE codex_turn_models (
    launch TEXT NOT NULL REFERENCES journal(launch_key) ON DELETE CASCADE,
    event TEXT NOT NULL,
    model TEXT NOT NULL,
    rerouted INTEGER NOT NULL,
    PRIMARY KEY (launch, event)
) WITHOUT ROWID;
PRAGMA user_version = 73;
COMMIT;
