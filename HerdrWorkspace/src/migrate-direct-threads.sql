BEGIN IMMEDIATE;
CREATE INDEX journal_direct_thread ON journal(in_reply_to,id) WHERE in_reply_to IS NOT NULL;
PRAGMA user_version = 26;
COMMIT;
