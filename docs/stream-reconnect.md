# Hermes stream recovery

Read-only inspection on 2026-10-21 of `/opt/hermes-core/current/src` on
195.201.33.222, source commit `e06df9c2eae6901f4c88f464e0ae6e753c0428b8`:

- `gateway/platforms/api_server.py:3612–3775`: the native session chat POST owns
  its agent task. A broken SSE writer invokes
  `_drain_session_stream_task_on_disconnect`, which interrupts the agent (or
  cancels the wrapper before the agent is registered). Reopening that POST is
  another turn, not a subscription.
- `gateway/platforms/api_server_runs.py:620–763`: `POST /v1/runs` returns a run ID
  and executes the run in a tracked background task. The idempotency store
  checks the principal/profile scope and body fingerprint before concurrency
  admission; replay returns the original run, while a changed body conflicts.
  `runs_idempotency` advertises `supported`, `durable`, and retention seconds.
- `api_server_runs.py:1057–1157`: `GET /v1/runs/{id}` returns the run status and
  terminal output; `GET /v1/runs/{id}/events` replays events after `Last-Event-ID`.
  Events include integer `seq`. The subscription's finally block detaches its
  queue, without interrupting the agent. `replay.truncated` announces a replay
  gap. Terminal `run.completed` includes the authoritative output.
- `tests/gateway/test_api_server_runs.py:test_reconnect_receives_exactly_missed_events_and_terminal`
  exercises detach, missed delta/steer events, and reconnect with Last-Event-ID.
- nginx `sites-enabled/published-konrad` uses `hermes_api` at 10r/s, burst 20,
  nodelay. No Hermes code/configuration or nginx configuration was changed.

The Mac now uses detachable runs when these capabilities and **durable**
idempotency are advertised. A lost submission acknowledgement is retried once,
with the same key and identical bytes, before any assistant output is consumed.
The server reservation prevents a duplicate execution even if the first POST
succeeded. Once a run ID exists, recovery only GETs that run: it never submits a
new turn, including after partial assistant text or tools.

A broken event subscription retries at 1, 2, 4, 8, and 15 seconds. Each delay is
followed by a status read: a terminal result replaces the preview; otherwise the
subscription resumes from its last successfully parsed sequence. Duplicate
sequences are ignored. After replay truncation, available events resume and the
terminal output repairs the incomplete preview. Fresh sequence progress or a
validated subscription lasting 30 seconds restores the full retry budget and
initial backoff. Replayed duplicates alone do not reset it. Cancellation ends recovery.
Explicit server failure/cancellation is not retried. Retry exhaustion retains
ambiguous-delivery semantics for the existing read-only reconciliation UI.
Recovery emits visible chat notices and status events. Run IDs are recorded even
when submission recovery emitted an earlier notice before the ID was known.

Wake and NWPathMonitor restoration/interface changes invalidate only detachable
subscriptions, using a generation to handle a concurrent subscription open.
Native POST streams are never cancelled by the connectivity handler.

Compatibility limits: confirmed Browser model locks still use native chat,
because `/v1/runs` does not pass `confirmed_runtime_lock` to `_create_agent`
(the native endpoint enforces routing and disables fallback). Image turns and
text over Hermes's per-part limit retain native content normalization.
Hermes 0.22 also redacts model_config in its session response, returning only
has_model_config. A session with opaque configuration retains native transport
because the client cannot safely rule out a confirmed lock. Management turns
retain native tool argument correlation. These native and
legacy turns retain the existing interrupted-turn reconciliation/manual retry;
automatically replaying a non-idempotent POST could repeat tool side effects.
No unsupported recovery promise is inferred from the server version.

Status polling GETs (health, Overview metadata, and run status) opt into an actor
queue and one timer. Session preflight, history, discovery, and other requests
bypass this queue; send-time capability reads retain their own coalescing registry.
Identical concurrent
URLs coalesce only within the same credential/profile scope. Reads are fresh
once the shared operation finishes; run/history results are never cached.
Origins share 300 ms spacing plus 0–100 ms jitter, a 150 ms debounce, and a cap
of two active reads. Each 429/503 extends a host-wide exponential cooldown
(2 seconds through 60 seconds), respecting Retry-After seconds/HTTP dates
(capped at 120 seconds). After four busy responses, status is deferred rather
than exposed as an HTTP failure; Overview keeps its last good data or displays
a paused status. Cancelling one reader preserves other subscribers; cancelling
the last reader removes queued work and cancels its fetch.

Swift regression coverage uses isolated URLProtocol fixtures and schedulers:
repeated drops, sequence replay, polled terminal success/failure/cancellation,
truncated replay, wake reconnect, cancellation, exact once admission replay,
retry exhaustion, transport compatibility, path transitions, coalescing,
fresh reads, debounce/jitter/spacing, host concurrency, host-wide busy backoff,
Retry-After parsing, and cancellation isolation. Run these only on the Mac.
