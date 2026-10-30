
## DIRECTION from Konrad (2026-10-20 07:49 Warsaw) — supersedes the 07:19/07:20 addendum below
**This supersedes the runtime-backend design** (core1–core4: a central backend in the runtime path, an edge relay with WSS dial-out, and server-driven state composed live by the backend).
- The frontend apps (Mac and mobile) talk DIRECTLY to Hermes for all normal work, as they do today.
- The central core server is NOT in the runtime path. Its only job is to update and distribute skills, tools, configuration, server-driven UI definitions and similar, so behaviour changes ship without recompiling the apps.
- If the core is down, everything keeps working. Only updates wait.
- Hermes is never modified.

CORE-PLAN.md (core5) is rewritten around this model. Konrad's keys sign versioned bundles; apps and boxes pull them, verify them, and keep the last good version. Approvals and keys stay app ↔ box.

---

## SUPERSEDED (2026-10-20 07:49): ADDENDUM from Konrad (07:19)
Konrad's preferred direction: the shared core runs on ONE central backend server of ours. Hermes boxes (local and remote) and the Mac and mobile apps connect to it as clients. Make this the primary architecture in CORE-PLAN.md. Cover: how boxes connect to it (outbound connections, auth), keeping approvals and keys device-signed end to end so the server can't forge them, a single point of failure and offline/degraded behaviour, multi-tenant isolation between boxes, data at rest, and hosting/cost notes (no provisioning, cost estimates only). Mention per-box alternatives only briefly as a comparison.

Key goal (Konrad 07:20): behaviour updates must ship server-side without recompiling or App Store review of the clients. Design the clients to render server-driven state and actions generically (e.g. approval cards, forms and flows described by the server), so only real UI changes need a new build. Cover the limits (App Store rules on downloaded code, security of server-driven UI, versioning and compatibility).

Layering (Konrad 07:20): frontend (Mac and mobile apps, UI only) -> backend (our one central server, all behaviour logic) -> Hermes (runtime on the boxes, called by the backend, never modified). Structure CORE-PLAN.md around these three layers and their interfaces.
