BEGIN IMMEDIATE;
-- Auto mode becomes the default. Until now a row first written by another setting (a helper model,
-- a spending limit, a move between servers) started with Auto off, which looked like the person's
-- choice. Turn Auto on once for every bot outside the two stricter roles. A bot the person turns
-- off afterwards stays off.
UPDATE bot_agent_settings
   SET auto_mode=1, auto_changed_ms=CAST(strftime('%s','now') AS INTEGER)*1000
 WHERE auto_mode=0 AND review_every_tool=0 AND document_read_only=0;
PRAGMA user_version=88;
COMMIT;
