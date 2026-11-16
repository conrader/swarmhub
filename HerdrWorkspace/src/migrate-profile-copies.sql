BEGIN IMMEDIATE;
CREATE TABLE profile_copy_setup (
  profile INTEGER PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  template TEXT NOT NULL,
  runtime TEXT,
  collect_results INTEGER NOT NULL CHECK(collect_results IN (0,1))
);
CREATE TABLE profile_copy_routines (
  id INTEGER PRIMARY KEY,
  profile INTEGER NOT NULL REFERENCES profile_copy_setup(profile) ON DELETE CASCADE,
  name TEXT NOT NULL, task TEXT NOT NULL, schedule TEXT NOT NULL
);
CREATE INDEX profile_copy_routine_profile ON profile_copy_routines(profile,id);
CREATE TABLE profile_copy_disabled_skills (
  profile INTEGER NOT NULL REFERENCES profile_copy_setup(profile) ON DELETE CASCADE,
  skill INTEGER NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  PRIMARY KEY(profile,skill)
);
PRAGMA user_version = 19;
COMMIT;
