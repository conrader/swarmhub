BEGIN IMMEDIATE;
ALTER TABLE bot_outbox ADD COLUMN delivery_receipt TEXT CHECK(delivery_receipt IN ('unsent','uncertain','expired','acknowledged'));
ALTER TABLE bot_outbox ADD COLUMN retry_after_ms INTEGER NOT NULL DEFAULT 0;
UPDATE bot_outbox SET delivery_receipt=CASE
 WHEN state='pending' THEN 'unsent'
 WHEN state='typed' AND EXISTS(SELECT 1 FROM journal WHERE id=bot_outbox.task AND state='sent') THEN 'acknowledged'
 WHEN state IN ('typing','typed') THEN 'uncertain'
 WHEN give_up_ms<=coalesce(typed_ms,created_ms) THEN 'expired' END
 WHERE cause IN ('message','outcome') AND NOT EXISTS(SELECT 1 FROM job_deliveries WHERE outbox=bot_outbox.id);
PRAGMA user_version = 67;
COMMIT;
