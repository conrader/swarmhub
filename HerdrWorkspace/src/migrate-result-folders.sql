BEGIN IMMEDIATE;
CREATE TABLE result_folders (
  launch INTEGER PRIMARY KEY REFERENCES journal(id)
);
PRAGMA user_version = 18;
COMMIT;
