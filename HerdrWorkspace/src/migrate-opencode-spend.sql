BEGIN IMMEDIATE;
ALTER TABLE bot_agent_settings ADD COLUMN session_cap_cents INTEGER CHECK(session_cap_cents > 0);
ALTER TABLE journal ADD COLUMN session_cap_cents INTEGER CHECK(session_cap_cents > 0);
ALTER TABLE journal ADD COLUMN spend_refusals INTEGER;
ALTER TABLE journal ADD COLUMN spend_refusal_reason TEXT;
CREATE TABLE opencode_spend (
    launch INTEGER NOT NULL REFERENCES journal(id) ON DELETE CASCADE,
    request TEXT NOT NULL,
    nanos INTEGER NOT NULL CHECK(nanos >= 0),
    settled INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (launch, request)
);
PRAGMA user_version=83;
COMMIT;
