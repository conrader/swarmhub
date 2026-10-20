"""Swarm Hub updater package (plan B, CORE-PLAN.md §3.4). Stdlib only, so the bootstrap package is self-contained.

P0b ships the verifier library: `verify` (verification order, docs/update-service/SCHEMAS.md §10), `jcs` (canonical
JSON profile), `ed25519` (verify-only RFC 8032) and `archive` (strict ustar rules and a contained extractor).
"""
