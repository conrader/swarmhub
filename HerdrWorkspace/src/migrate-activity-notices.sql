BEGIN IMMEDIATE;
-- A fast agent can publish before terminal.run returns. Advance its cursor
-- when the reply becomes navigable so an open browser cannot miss it.
CREATE TRIGGER workspace_activity_now_visible AFTER UPDATE OF address ON journal
WHEN OLD.address IS NULL AND NEW.address IS NOT NULL AND NEW.kind IN ('reply','artifact')
BEGIN
  UPDATE workspace_activity SET id=(SELECT coalesce(max(id),0)+1 FROM workspace_activity)
  WHERE journal_id=NEW.id;
END;
PRAGMA user_version = 29;
COMMIT;
