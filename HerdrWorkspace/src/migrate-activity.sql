BEGIN IMMEDIATE;
CREATE TABLE workspace_activity (
  id INTEGER PRIMARY KEY,
  journal_id INTEGER UNIQUE REFERENCES journal(id) ON DELETE CASCADE,
  group_message_id INTEGER UNIQUE REFERENCES group_messages(id) ON DELETE CASCADE,
  unread INTEGER NOT NULL DEFAULT 1 CHECK (unread IN (0,1)),
  CHECK ((journal_id IS NULL) <> (group_message_id IS NULL))
);
CREATE INDEX workspace_activity_unread ON workspace_activity(id) WHERE unread=1;
INSERT INTO workspace_activity (journal_id,group_message_id,unread)
SELECT jid,mid,0 FROM (
  SELECT id AS jid,NULL AS mid,at_ms FROM journal
  WHERE kind IN ('reply','artifact') AND address IS NOT NULL AND created_ms IS NOT NULL
  UNION ALL
  SELECT NULL,id,at_ms FROM group_messages WHERE author IS NOT NULL AND is_question=0
  ORDER BY at_ms DESC LIMIT 100
) ORDER BY at_ms,jid,mid;
CREATE TRIGGER workspace_direct_activity AFTER INSERT ON journal
WHEN NEW.kind IN ('reply','artifact')
BEGIN
  INSERT INTO workspace_activity (journal_id) VALUES (NEW.id);
END;
CREATE TRIGGER workspace_group_activity AFTER INSERT ON group_messages
WHEN NEW.author IS NOT NULL AND NEW.is_question=0
BEGIN
  INSERT INTO workspace_activity (group_message_id) VALUES (NEW.id);
END;
PRAGMA user_version = 28;
COMMIT;
