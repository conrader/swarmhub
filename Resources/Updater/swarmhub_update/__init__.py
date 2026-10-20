"""Swarm Hub updater package (plan B, CORE-PLAN.md §3.4). Stdlib only, so the bootstrap package is self-contained.

P0b ships the verifier library: `verify` (verification order, docs/update-service/SCHEMAS.md §10), `jcs` (canonical
JSON profile), `ed25519` (verify-only RFC 8032) and `archive` (strict ustar rules and a contained extractor).
P0d adds `render` (SkillLibrary.render port). P2a adds the apply engine: `stage` (render into a staging folder,
post-apply checks), `idle` (no running code-job or swarm job, bounded wait) and `apply` (atomic swap, `previous`,
revert, crash recovery, `reload_pending`). P2b adds the command line (`cli`, launcher `bin/swarmhub-update`):
`pins` (the admin-owned pin file: roots, floor checkpoint, revoked key IDs), `state` (floors, stored bundle,
applied record, status file), `bundle` (staged/stored verification, component contents), `policy` (decision 2, per
component) and `runner` (applying through the engine, status). P3a adds pull: `fetch` (outbound HTTPS, the only
module that opens a network connection), `channel` (origins, service layout, rollout view) and `compat` (Hermes
version read as text, incompatible axes).
"""

VERSION = "1.0.0"  # the `updater` axis of requires maps (SCHEMAS.md §8)
