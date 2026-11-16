BEGIN IMMEDIATE;
ALTER TABLE profiles ADD COLUMN avatar_key TEXT;
CREATE TABLE profile_avatars (
    profile INTEGER PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    png BLOB NOT NULL
);
PRAGMA user_version = 21;
COMMIT;
