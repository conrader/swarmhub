# Live pass 6: observed Grok patterns and CLI isolation

**7 matches / 3 worse / 0 missing at the managed-runtime boundary.** Pass 5 was
6/4/0. P06 improves because the live reply now follows the secret-request fence
contract. P07's approval fence also works, but its corrected coding job remains
blocked in this session's nested shell. This is not native-app or deployed-agent
10/10 acceptance.

Replay: **2026-10-19 12:37:23–12:40:11 UTC / 14:37:23–14:40:11 Warsaw**.
Checkout **`2cb8260`**, bundled messaging skill **1.3.3**, installed authenticated
Codex CLI **0.163.0**, explicit **`gpt-6-astra` / `high`**. No commit or deploy.
Hermes source, installation, configuration and running gateway were not modified.
All outbound operations were FAKE; provisioning used only a local synthetic hook.
No source auth/config was written, and no secret values were exported.

## Boundary and execution path

Read [pass 5](LIVE-REPORT-5.md), the gaps3 smoke/reproduction artifacts, commit
`df9a135`, and the [recorded Grok patterns](../grokbot-observed.md). Grok was not
rerun. Its observed summaries supply the comparison; QA prompts preserve their
roles and contracts with explicit synthetic substitutions.

The [runner](sim/live_managed.py) uses shipped `swarmctl`, `code-job` and
`bot-msg --durable`, plus held and asynchronous priority messages. Five QA role
profiles map to ten receiving sessions on the existing QA Hermes at loopback
port 8742. A temporary loopback bridge invokes the shipped pre/post hooks and
passes their context, plus the actual 1.3.3 skill's approval/secret instructions,
into real Hermes turns. Hermes still exposes only `todo` and `clarify`; neither
was used. The runner initiates commands. Owner decisions are labelled local
QA-Konrad administrative fixtures. These are not native clicks, installed plugin
activation, five provisioned agents, or proof of autonomous model tool execution.

**Every real CLI attempt used the sandboxed `exec_command` shell**, including the
direct-subprocess reproduction-style probe, P01, P04's shared coding evidence,
and P07's running/corrected jobs. P06 has no real CLI job: its provisioner is
explicitly synthetic. A zero-provider-call [sandbox probe](sim/results/live-6-validation/QA-sandbox-probe.json)
confirmed the known socket-directory failure before coding. The direct
[CLI probe](sim/results/live-6-cli-probe/QA-cli-smoke.json) retained the same failure.

The brief's successful plain-box-shell route was **not available through this
session's tools**. I requested its launcher while continuing the replay; none
was supplied. I did not disable a sandbox, change the masked shared socket
directory, or describe a nested run as plain-shell acceptance. The prior gap1
plain-shell success remains evidence that this is a nested-environment artifact;
these failures do not reopen it as an application defect. Successful pass-6 coding
acceptance on that route remains outstanding.

## Isolation fix and evidence

`writable_cli_state` previously symlinked `auth.json` and `config.toml` into the
source home. CLI project-trust writes could follow that config link. It now
creates independent regular **0600** copies inside its private **0700** home,
with separate **0700** runtime and temporary directories. Even `login status`
uses disposable copies. After the replay, discovery also received a private
0700 `HOME`; a real login-status check confirmed authentication and unchanged
source files with zero provider calls. The new [CLI probe](sim/live_cli_probe.py), discovery,
and full replay assert unchanged source auth/config contents, mode, inode and
mtime. They export no credential/config values or credential hashes.

This was exercised live: CLI startup added the QA repository's trust entry to
the **private** config; the source config contained no entry for that repository.
The source remained unchanged after the full replay and after the separate CLI
probe. Both private credential/config files were regular 0600 files.
[Private-write evidence](sim/results/live-6/QA-private-cli-writes.json),
[end-of-replay assertions](sim/results/live-6/QA-cli-isolation.json),
[probe assertions](sim/results/live-6-cli-probe/QA-cli-smoke.json).

Offline regressions additionally mutate private trust/config and credentials,
including during login discovery, and verify that the source is unchanged and
discovery copies are removed. No source file was restored or edited as cleanup.
Changes are limited to harness isolation, probe, prompts, assertions and docs;
shipped runtime and app code are unchanged.

## Per-pattern grades versus pass 5

`matches` means the executed managed contract matches the recorded behavior
within the boundary above. `worse` includes an unmet portion or environment
blocker; it does not by itself identify a product bug.

| Pattern | Pass 5 → pass 6 | Evidence and practical limit |
| --- | --- | --- |
| **P01 — completion wakes Jarvis and advances work** | worse → **worse** | Real CLI job `job.ad8bfcc6207f4f258b5f82822effd93e` exits 0 without a fresh report; `code-job` correctly fails **65**, `report-valid=false`, `tests-passed=not-run`, `evidence=none`. Jarvis's real receiving turn **002** rejects completion. The second job remains queued; it is not falsely reported as launched. Successful coding, commit/rebuild and successful unattended queue advance remain unproven. **Path: nested shell.** [Queue before teardown](sim/results/live-6/QA-P01-CLI-queue.json), [CLI/model audit](sim/results/live-6/QA-audit.json). |
| **P02 — unknown origin falls back to Jarvis; keyed webhook** | matches → **matches** | Deliberately CLI-free unknown-origin job `job.IxMS4XUO` fails 69 and wakes Jarvis in **008**. `QA-Infra/QA-wake` registration is idempotent; key file 0600, directory 0700; only its path is exposed. CLI fire and rotated-key HTTP fire produce two real durable self-wakes (**012/014**), `fired=2`. Old key fails CLI **77** and HTTP **403**; new key returns **202**. No Hermes routine or public endpoint was installed. [Fallback](sim/results/live-6/QA-P02-fallback.json), [webhook](sim/results/live-6/QA-P02-webhook.json). |
| **P03 — hold FYIs, prioritize asks** | matches → **matches** | Held FYI admission causes zero HTTP/model turns. The actual pre-hook injects it into Ermes's priority turn **016**, and the post-hook marks it delivered. `--priority --no-wait` admits in **0.036 seconds** before the answer; its one return delivery receives `NO_REPLY` in **020**. The early snapshot precedes asynchronous completion; final inbox/hook evidence establishes delivery. [Audit](sim/results/live-6/QA-audit.json), [final inbox](sim/results/live-6/QA-final-local-state.json), [hooks](sim/results/live-6/results.json). |
| **P04 — coordinator rejects empty jobs and requires explicit execution/evidence** | worse → **worse** | P01's real CLI/high run is rejected for no report. A second, deliberately CLI-free failed job has a configured verification command that never runs. The actual wake says **“verification configured but not run”**; Swarmhub's separate correction turn **010** explicitly requires `gpt-6-astra`, high effort, a fresh nonempty report and passing verification, and denies any established relaunch. Receipt wording is fixed and live correction is stronger than pass 5's `NO_REPLY`; successful corrective work is still unproven. **Real coding evidence path: nested shell; negative routing control: intentionally no CLI.** [Commands/wakes](sim/results/live-6/results.json), [answers](sim/results/live-6/QA-audit.json). |
| **P05 — 95% quota broadcast routes to Codex and stops speculation** | matches → **matches** | Revision **4** persists Codex, `gpt-6-astra`, `allow_speculative=false`. Swarmhub/Infra/Ermes acknowledge revision 4 and answer `NO_REPLY` (**018/022/024**). Planning Claude resolves Codex; speculative admission exits **64**. The 95% observation is supplied, not freshly measured; no Hermes provider switch is claimed. [Policy/acks](sim/results/live-6/QA-P05-policy-acks.json). |
| **P06 — Ermes provisioning, private secret path, secure key request** | worse → **matches** | Synthetic intake creates a generated-value 0600 file. The configured local synthetic provisioner remains awaiting owner without a receipt, rejects the wrong actor **64**, then completes **exit 0** after the QA-Konrad fixture approval. Ermes's real turn **016** reports the path and synthetic boundary and emits an exact `swarmhub` secret-request fence for `QA-model-key`. Its unchanged required-field guards accept the reply in the source-derived parser mirror. This closes the pass-5 live output-contract failure; real provisioning, user-secret acquisition and native sheet interaction remain outside this grade. **No CLI job.** [Provision journal](sim/results/live-6/QA-P06-synthetic-provision.json), [raw reply and parser projection](sim/results/live-6/QA-audit.json). |
| **P07 — owner/coordinator gates, cards, interrupt/relaunch** | worse → **worse** | Money/prod/secrets await owner; fixture denials are final and resubmission fails **64**. Turn **026** presents the actual pending money task in an exact approval fence accepted by the source-derived field guards. Scope replacement cancels the parent/peer tree and suppresses obsolete held work. A real CLI PID is alive before replacement, then gone with **cancelled / exit 125**. Its corrected job launches the real CLI but fails **65**, `evidence=none`. Exact app-shaped FAKE draft submission is idempotent and finishes FAKE. Card output is fixed, but successful corrected coding and native card/decision/Draft Send interaction remain unverified. **CLI path: nested shell.** [Tree](sim/results/live-6/QA-P07-scope-cancel.json), [running cancellation](sim/results/live-6/QA-P07-running-scope-killed.json), [final corrected job](sim/results/live-6/QA-final-local-state.json). |
| **P08 — Warsaw reporting hours** | matches → **matches** | At actual **14:40 Warsaw**, report selects **QA-Jarvis + QA-Konrad**. Both rows become delivered and both receiving turns (**034/036**) return `NO_REPLY`. Nighttime and DST branches remain offline coverage; the clock was not fabricated. No real contact with Konrad. [Delivery](sim/results/live-6/QA-P08-report-delivery.json). |
| **P09 — autonomous allowlist; outbound FAKE** | matches → **matches** | Allowlisted `/bin/pwd` finishes **auto / done / exit 0** without an approval decision. FAKE outbound records bind exact QA recipient/text and finish **done / FAKE: no outbound operation executed**; their `touch` marker is never created. Admission/execution are real, initiated by the runner. [Actions/drafts](sim/results/live-6/QA-P09-autonomy.json). |
| **P10 — unreachable target retained and retried** | matches → **matches** | Closing only the temporary bridge yields **pending**, attempt **1**, exit **3**, retained for retry. Restoring that listener lets the existing worker deliver on attempt **2**, producing exactly one Ermes turn **038**. No caller resend, manual tick or due-time change; Hermes stays running. [Offline](sim/results/live-6/QA-P10-unreachable-pending.json), [automatic retry](sim/results/live-6/QA-P10-automatic-retry.json). |

## Comparison and remaining blockers

Compared with pass 5, P06 advances to a match at the stated managed boundary.
P07's live approval formatting also succeeds. Both replies use exact fences, so
this pass tests model compliance with the revised instructions; the bare-JSON
fallback remains covered by the existing 43 offline fixtures, not by native Swift
execution. P04 now has a substantive real correction reply and correct receipt
wording. The new isolation bug is closed by private copies and observed private
trust writes with unchanged source files.

The remaining blockers to 10/10 are:

1. **Successful coding acceptance on the plain-shell route.** P01/P04/P07 still
   need fresh accepted reports, passing verification and successful queue/relaunch
   evidence from an available plain box shell. Commit/rebuild behavior also remains
   unproven. This session's nested tool failures are not app defects. The new probe
   can be run on that route without changing `code-job` or the source auth home:
   `python3 -B sim/live_cli_probe.py --output <fresh-QA-evidence-dir> --execution-path plain-box-shell`
   with the installed authenticated CLI on PATH. A successful probe alone would
   still need the managed queue/relaunch replay.
2. **Native app acceptance.** Swift is unavailable on this Linux host. Source-derived
   parsing of the exact live replies does not prove card rendering, the secure
   sheet, same-box decision routing, human decisions, or Draft Send. These remain
   app-side validation gaps; no app features were built here.
3. **Deployed autonomous integration.** The bridge invokes hooks externally and
   Hermes's available tools cannot run managed shell commands. The model does not
   independently inspect artifacts, rebuild, or relaunch jobs. Normal plugin
   installation/discovery, bot-initiated orchestration, native goal verification,
   real provisioning/key handoff and owner/coordinator interaction need their
   actual deployed environments. Public webhook/TLS and real outbound behavior
   were intentionally outside this FAKE-only replay.

## Validation, call accounting and cleanup

- Full replay: **113 low-level checks pass, 3 fail**. The failures are retained:
  first coding job verification, automatic next-job launch, corrected-scope
  verification. The runner completes cleanup even with those failed results;
  its process exit 0 is not a passing acceptance verdict.
- **19 Hermes turns / 19 observed provider calls**, zero Hermes tool calls,
  **91 runner HTTP requests**, ten receiving sessions. The subsequent independent
  cleanup audit adds **30 read-only GETs**, with no model turns.
- Real CLI transcripts record **8 provider responses** across P01 and corrected
  P07; the separate probe records **5**. Total: **32 observed model calls**, under
  approximately 60. Cancellation before a CLI transcript can hide an in-flight
  request, so this is not a billing total. [Calls and exact answers](sim/results/live-6/QA-audit.json),
  [owned-session telemetry](sim/results/live-6/usage-snapshots.json).
- Final offline suite: **129 passed, 0 failed, 0 skipped**, including discovery
  mutation isolation and the existing 43 parser fixtures. [Log](sim/results/live-6-validation/QA-python-tests.txt).
  Socket suites: **14 passed under sh + 14 under dash**, no failures/skips.
  [sh](sim/results/live-6-validation/QA-bot-msg-sh.txt), [dash](sim/results/live-6-validation/QA-bot-msg-dash.txt).
  The five isolation/parser regressions and detection/gap tests were rerun after
  the final discovery-HOME change. [Isolation](sim/results/live-6-validation/QA-isolation-tests.txt),
  [gap tests](sim/results/live-6-validation/QA-gap-tests-final.txt),
  [real discovery](sim/results/live-6-validation/QA-final-discovery.json).
  Changed Python syntax and `git diff --check` pass. Native Swift/UI was not run.
- All **19 exact owned runs** were independently checked terminal; all **10 exact
  owned sessions** return **404**. The runner verified no owned local processes
  remain in its namespace, closed its bridge/receiver, and removed temporary QA
  profiles, credential/config copies, secret intake, webhook keys, repository and
  runtime state. The independent audit confirms the temporary state is absent.
  Final health: **active runs 0, active agents 0, gateway_busy false**.
  [Cleanup verification](sim/results/live-6/QA-cleanup-verification.json).
- Reports, small harness changes and evidence remain **uncommitted**.
  [Source provenance](sim/results/live-6/QA-provenance.json),
  [commands/SSE/hooks](sim/results/live-6/results.json),
  [run log](sim/results/live-6-validation/QA-live-run.txt),
  [delivery log](sim/results/live-6/QA-bot-messages.tsv),
  [final local journal](sim/results/live-6/QA-final-local-state.json).
