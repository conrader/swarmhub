BEGIN IMMEDIATE;
CREATE TABLE grok_skill_drafts (
    id INTEGER PRIMARY KEY,
    fingerprint BLOB NOT NULL UNIQUE,
    source_file TEXT NOT NULL,
    name TEXT NOT NULL,
    instructions TEXT,
    state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','saved','dismissed')),
    skill INTEGER REFERENCES skills(id),
    CHECK((state='saved')=(skill IS NOT NULL)),
    CHECK((state='pending')=(instructions IS NOT NULL))
);
PRAGMA user_version = 45;
COMMIT;
