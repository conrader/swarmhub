BEGIN IMMEDIATE;
CREATE TABLE library_pins (
    kind TEXT NOT NULL CHECK(kind IN ('page','file','snapshot')),
    item_id INTEGER NOT NULL,
    PRIMARY KEY(kind,item_id)
) WITHOUT ROWID;
PRAGMA user_version = 37;
COMMIT;
