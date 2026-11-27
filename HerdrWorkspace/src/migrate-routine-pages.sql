BEGIN IMMEDIATE;
-- A published brief belongs to its saved result even if its schedule is subsequently removed.
CREATE TABLE routine_result_pages (
    result INTEGER PRIMARY KEY REFERENCES journal(id) ON DELETE CASCADE,
    page INTEGER NOT NULL,
    revision INTEGER NOT NULL,
    FOREIGN KEY(page,revision) REFERENCES workspace_page_versions(page,revision) ON DELETE CASCADE
);
CREATE INDEX routine_page_versions ON routine_result_pages(page,revision);
DROP TRIGGER workspace_page_revised;
CREATE TRIGGER workspace_page_revised AFTER UPDATE OF revision ON workspace_pages
WHEN NEW.revision != OLD.revision BEGIN
    INSERT INTO workspace_page_versions VALUES (NEW.id,NEW.revision,NEW.title,NEW.markdown,NEW.updated_ms);
    DELETE FROM workspace_page_versions WHERE page=NEW.id AND revision<=NEW.revision-50
        AND NOT EXISTS (SELECT 1 FROM routine_result_pages r
                        WHERE r.page=workspace_page_versions.page AND r.revision=workspace_page_versions.revision);
END;
PRAGMA user_version=86;
COMMIT;
