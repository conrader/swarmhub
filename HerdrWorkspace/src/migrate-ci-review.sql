BEGIN IMMEDIATE;
ALTER TABLE bot_checkins ADD COLUMN ci_reviewed INTEGER NOT NULL DEFAULT 0 CHECK(ci_reviewed IN (0,1));
CREATE INDEX bot_unreviewed_ci ON bot_checkins(id DESC)
    WHERE ci_reviewed=0 AND json_extract(schedule,'$.kind')='ci' AND json_extract(schedule,'$.failure') IS NOT NULL;
PRAGMA user_version = 74;
COMMIT;
