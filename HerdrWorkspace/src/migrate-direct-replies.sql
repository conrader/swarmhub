BEGIN IMMEDIATE;
ALTER TABLE journal ADD COLUMN in_reply_to INTEGER REFERENCES journal(id);
ALTER TABLE journal ADD COLUMN reply_excerpt TEXT;
PRAGMA user_version = 25;
COMMIT;
