BEGIN IMMEDIATE;
CREATE TABLE workspace_pages (
    id INTEGER PRIMARY KEY,
    owner_launch TEXT REFERENCES journal(launch_key),
    title TEXT NOT NULL,
    markdown TEXT NOT NULL,
    updated_ms INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1
);
ALTER TABLE journal ADD COLUMN page_id INTEGER REFERENCES workspace_pages(id);
PRAGMA user_version = 15;
COMMIT;
