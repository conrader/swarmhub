# Known gaps

- swarm_devices.ancestors() passes the ancestry check when ppid is 0 (caller in a foreign PID namespace); the HERMES_* env check runs first. Left as-is by decision (Oct 23, 2026); failing closed would break namespaced fixtures.

> Archived from root on 2026-11-11; see [living limits](../../ROADMAP-AND-LIMITS.md).
