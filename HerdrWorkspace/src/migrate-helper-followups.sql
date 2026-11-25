BEGIN IMMEDIATE;
CREATE TABLE helper_followups (
    task INTEGER PRIMARY KEY REFERENCES journal(id),
    launch INTEGER NOT NULL REFERENCES helpers(launch),
    bot TEXT NOT NULL REFERENCES bots(id),
    instruction TEXT NOT NULL,
    outbox INTEGER UNIQUE REFERENCES bot_outbox(id),
    cancelled INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX pending_helper_followups ON helper_followups(launch) WHERE outbox IS NULL AND cancelled=0;
PRAGMA user_version = 70;
COMMIT;
