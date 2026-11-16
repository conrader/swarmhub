BEGIN IMMEDIATE;
CREATE TABLE direct_task_files (
    id INTEGER PRIMARY KEY,
    task_id INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    data BLOB NOT NULL
);
CREATE INDEX direct_files_by_task ON direct_task_files(task_id,id);
PRAGMA user_version = 38;
COMMIT;
