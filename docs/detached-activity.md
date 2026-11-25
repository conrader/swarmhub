# Detached sb-codejob activity

The Mac app's terminal badge lights when the bridge confirms a live Codex or Claude executable for that bot. Overview shows the same observation with its host and a short job ID. A bot can have a worker without a Herdr terminal or a native helper. Native helper details and terminals still use the existing Herdr session. Detached rows are read-only.

## Configure the bridge

Use the updated app and bridge. At deployment, set `SWARMHUB_CODEJOB_HOSTS` in the **workspace bridge service's environment** to a JSON array. An unset variable or `[]` enables zero hosts. Restart the bridge to pick up a changed service environment. Use the following as a template for a DMT project server. Substitute the actual persistent Herdr machine name and SSH target, runner account paths, hostname, and SwarmHub bot UUID from the team registered on **this bridge**. The UUID below is a fixture. Keep this configuration under operator control.

```json
[{
  "id": "dmt",
  "machine": "dmt",
  "target": "runner@dmt.example",
  "scope": {
    "hostname": "serwerDMT",
    "runner_host": "serwerDMT",
    "root": "/home/runner/work",
    "owners": [{
      "agent": "Swarmhub",
      "workdir": "/home/runner/work/Swarmhub",
      "bot_id": "00112233-4455-6677-8899-aabbccddeeff"
    }],
    "executables": {
      "codex": "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
    }
  }
}]
```

* For the bridge Core's own host, omit both `machine` and `target`. For another machine, Core must already have a connected, persistent, direct registration with the exact configured target. Normal SSH host-key verification and the existing authenticated bridge connection apply. The app uses its existing local, address or SSH-forwarded server watch. A closed, unwatched forward provides no observation.
* Each host needs Herdr Core with `machine.exec` and `/usr/bin/python3` (3.8 or newer). Remote enumeration also uses `machine.list`. The workspace calls one embedded, fixed reader per configured host during the helper roster GET. Scope and arguments come exclusively from the service environment. No install on the worker is needed for the reader.
* Use a stable, unique host ID and the kernel hostname. `runner_host` must equal the record's `host`, including case and any runner override. Give the actual status root. Standalone Linux DMT/OVH normally use the runner account's `$HOME/work` or `SB_CODEJOB_WORKROOT`. Box mode uses `$SB_CODEJOB_ROOT/logs` (default `/workspace/jobs/logs`) and typically records `box`.
* The existing Core login must already own and be able to read the private 0600 status files, see the supervisor and worker processes in their PID namespace, and inspect their execution identity. The owner directory must be owned by that account and protected against group/other writes. Supply absolute physical paths without symlink directory components. Jobs from a different Unix account require a separately authorized source. Do not change runner permissions or elevate the reader.
* Bind each runner agent directory and recorded workdir subtree to the intended bot UUID. Use distinct subtrees if two bots submit under the same runner agent. A record matching multiple bindings makes that host incomplete and produces no attributed row. This trusts the operator's configured runner account and its status writer. Workloads sharing that account can alter its files.
* Pin the actual native worker executable for each supported provider. For npm Codex this is the native binary under the platform package. Claude Code can use its installed native executable or a symlink resolving to it. Update the pin when the installation moves. A shared interpreter such as Node, Python, or the shell is unsuitable as a provider pin.

## Coverage and freshness

Linux verifies the boot ID, primary and supervisor PID/start ticks, the parent relationship and a live executable in the primary's process tree. macOS uses the runner's C-locale `ps lstart` tokens, parent PID and `ps comm` executable path from a single same-user process snapshot. A visible Linux kernel lock wait can be shown as queued. A shell waiting on a timer, an unrecognized program, or a macOS wrapper with no observed provider is shown as a running wrapper with worker status unconfirmed. Only a verified worker lights the detached badge.

A recorded exit, a changed Linux boot ID or a verifiably gone or reused primary PID removes the job. Missing identity tokens, stopped processes or inaccessible process evidence leave its status unknown. Missing directories, denied access, an incompatible Core, invalid configuration, a truncated response or a disconnected machine leave coverage incomplete. Other configured hosts can still report activity. Refresh replaces the previous snapshot. The app discards detached activity after a failed workspace read, a closed unwatched forward, or 25 seconds from the start of an observation. Ordinary workspace reads omit the probe. The helper watch requests `GET /api/workspace?codejobs=true`.

Host discovery is opt-in, with up to eight entries per bridge. DMT, OVH, Box and Macs need their own verified configuration and readable runner data. The feed covers native Codex and Claude executables, including descendants of shell wrappers. Its record source is sb-codejob primary-job JSON. Managed fixture attempts, sb-macjob completion notifications, model ledgers, review/then phases, arbitrary coding processes and unconfigured machines are outside this feed. The DTO contains a configured host ID, bot UUID, opaque job hash, state and provider. Commands, task labels, paths, logs, prompts and process environments stay off the app wire.

## Reproduce with isolated fixtures

On the DMT authoring host, `/usr/local/bin/sb-codejob` resolved to `/usr/local/lib/sb-codejob/sb-codejob` (SHA-256 `222aaa599f96662a9fd8877bfa280d0c1bf13465d824221b132de650dfd1096f`). Its `launch_job` and `supervise` atomically write `<root>/<agent>/<UTC timestamp>-<slug>[-N].json`, then update the same file with `ended` and `exit_code`. The authoring job itself recorded `primary_tool: null` and `kill_guard: shim`. A label or primary tool declaration cannot establish that a worker has started.

From this checkout, the following runs the installed runner's launcher, supervisor and status writer against a temporary home, gated wrapper and harmless compiled worker. The fixture uses the installed GroupPopen and checks its process group and session. It suppresses post-exit group cleanup after its child exits and suppresses completion delivery. The test waits for the real status writer's completion. It reads no production log or credential.

```sh
python3 HerdrWorkspace/tests/codejob_activity.py --runner "$(command -v sb-codejob)"
```

On **mini-m4**, use a logged-in macOS desktop session, Xcode Command Line Tools, Swift 6, Rust 1.95 or newer, and the project's SwiftPM/Cargo dependencies. Run this block from the repository root with these edits present.

```sh
(
  set -eu
  scratch=$(mktemp -d)
  export CARGO_TARGET_DIR="$scratch/target"
  cargo test --locked --manifest-path HerdrWorkspace/Cargo.toml --bin swarmhub-herdr codejob_activity
  cargo build --locked --manifest-path HerdrWorkspace/Cargo.toml
  python3 HerdrWorkspace/tests/codejob_activity.py \
    --integration --bridge "$CARGO_TARGET_DIR/debug/swarmhub-herdr" \
    --write-rosters "$scratch/rosters.json"
  SWARMHUB_CODEJOB_TEST_ROSTERS="$scratch/rosters.json" \
    swift test --filter HerdrCodingAgentTests
)
```

The Swift ingestion test captures workspace GET responses using the integration fixture by default. Set `SWARMHUB_TEST_BRIDGE` to the candidate executable when it is outside the debug target directory. Put the compatible runner and `hc` on PATH, or pass their paths with `--runner` and `--core` when capturing rosters separately. The fixture verifies a live worker through a private local Core and checks offline, replaced and recovered remote targets using a separate Core RPC peer. Process-only runs exercise the probe without the workspace HTTP transport.
