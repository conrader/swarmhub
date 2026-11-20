CREATE TABLE person_profile_history (
    id INTEGER PRIMARY KEY,
    timezone TEXT,
    location TEXT,
    updated_at INTEGER NOT NULL
);
ALTER TABLE bot_promises ADD COLUMN local_schedule TEXT;
PRAGMA user_version = 62;
