BEGIN IMMEDIATE;
CREATE TABLE workspace_page_versions (
  page INTEGER NOT NULL REFERENCES workspace_pages(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL,
  title TEXT NOT NULL,
  markdown TEXT NOT NULL,
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY(page,revision)
) WITHOUT ROWID;
INSERT INTO workspace_page_versions
  SELECT id,revision,title,markdown,updated_ms FROM workspace_pages;

CREATE TRIGGER workspace_page_created AFTER INSERT ON workspace_pages BEGIN
  INSERT INTO workspace_page_versions VALUES (NEW.id,NEW.revision,NEW.title,NEW.markdown,NEW.updated_ms);
END;

CREATE TRIGGER workspace_page_revised AFTER UPDATE OF revision ON workspace_pages
WHEN NEW.revision != OLD.revision BEGIN
  INSERT INTO workspace_page_versions VALUES (NEW.id,NEW.revision,NEW.title,NEW.markdown,NEW.updated_ms);
  DELETE FROM workspace_page_versions WHERE page=NEW.id AND revision<=NEW.revision-50;
END;
PRAGMA user_version = 36;
COMMIT;
