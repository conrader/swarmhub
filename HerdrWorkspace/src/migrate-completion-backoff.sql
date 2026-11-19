BEGIN IMMEDIATE;

ALTER TABLE job_deliveries ADD COLUMN retry_exponent INTEGER NOT NULL DEFAULT 0
  CHECK (retry_exponent BETWEEN 0 AND 5);

PRAGMA user_version = 61;
COMMIT;
