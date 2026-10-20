# System-prompt review follow-up

Review target: `10aaf25`; comparison base: `749d826`. Read-only local Hermes inspection, no external network, no changes to Hermes.

## Hermes combines both prompt channels

Source root on this host: `/home/ubuntu/hermes-0217-release/scratch/opt-real-a/0.21.7/src/`.

| Source relative to that root | Evidence |
| --- | --- |
| `gateway/platforms/api_server.py:3137`, `:3163–3168` | Creation reads `system_prompt` and stores it in the session row. |
| `gateway/platforms/api_server.py:3370`, `:3404`, `:2392` | A native turn takes `instructions` (or `system_message`) as `ephemeral_system_prompt` and passes it to the agent. |
| `agent/conversation_loop.py:750–759`, `:795–797` | Continuing conversations can restore the persisted `system_prompt` into `_cached_system_prompt`. |
| `agent/turn_context.py:1336–1344` | Model request assembly concatenates the active cached prompt and ephemeral prompt with two newlines. It does not deduplicate the app policy. |
| `agent/codex_runtime.py:494–499` | The Codex provider uses the same concatenation for developer instructions. |

A read-only source probe compiled only `_codex_developer_instructions` in memory: a saved policy plus the same ephemeral policy produced two copies; a saved custom persona plus ephemeral policy produced one. No Hermes package was imported or edited.

The corresponding files in `/home/ubuntu/hermes-0220-release/scratch/opt-real-a/0.22.0/src/` have the same prompt-handling code. Restoring depends on history/runtime state; the API offers no guarantee that turn instructions replace the saved prompt. Therefore sending the policy in both channels is unsafe.

Mac creation now stores the caller's persona verbatim, as before the feature; iOS creation stores the pre-feature empty string. Each native turn supplies the current app policy in `instructions`; the Mac legacy transport still supplies it in the initial system message. Existing sessions are neither rewritten nor recreated. Custom personas, management instructions, connected-app instructions, and server-owned prompts retain their existing paths.

The regression tests combine captured creation prompts with captured turn instructions and count one policy, rather than checking HTTP bodies independently. They cover the first turn, another turn, a separately resumed session with a custom saved persona, Mac legacy sends, and refreshed Mac app settings after creation. Native turn bodies must contain only `input` and `instructions`.

## Static Swift review

Swift is unavailable (`command -v swift` returns no executable). These are manual/static checks, not compiler or runtime verification. Reviewed all 17 changed/added Swift files relative to `749d826`, including the two edited OpenClaw tests:

| Files | Checks |
| --- | --- |
| `Configuration/BotSystemPrompt.swift` | Public context/init and public render/compose/wrap/strip APIs; Codable/Sendable stored fields; Foundation JSON/string/range APIs; all argument labels. |
| `HermesClient.swift`, `HermesClient+Streaming.swift` | Public initializer retains defaulted `session:` and adds defaulted `promptContext:`; Sendable context; same-module access from extension; throwing render inside `do`; Foundation/conditional FoundationNetworking imports. |
| `Apps/iOS/Sources/MobileStore.swift` | SwarmHubCore import present; both initializer calls use the correct labels/order and public BotPromptContext initializer. |
| `HermesBackend.swift`, `HermesBackend+Messages.swift` | Defaulted memberwise initializer remains compatible; SwarmHubCore import at compose calls. The three extracted static message helpers are byte-identical, retain internal access and use only internal symbols/Foundation. No private declarations move across file boundaries. |
| `OpenClawBackend.swift`, `OpenClawBackend+Chat.swift`, `OpenClawHistory.swift` | SwarmHubCore imports; internal defaultInstructions member and memberwise labels; String envelope input/output; GatewayJSON construction unchanged. |
| `AppStore.swift`, `AppStore+BoxSetup.swift`, `AppStore+SystemPrompt.swift` | Throw handling; existing main-actor isolation; memberwise argument order/defaults; checked orientationCoordinator(for:), ApprovalRouter.candidates(bot:global:), scopeLabel(_:), ApprovalRoute.label(reviewerName:), QuietHours.label, bot/store property names and types. |
| Core `ClientTests.swift`, core `SystemPromptTests.swift` | Mock handler throws and is Sendable; prompt log state protected by NSLock in synchronous methods; stream iteration and #require unwrapping; context initializer labels; String/Data decoding APIs. |
| App `SystemPromptTests.swift` | AgentRequest argument order/defaults; ChatParityServer reply/body types; Sendable handler captures; actor isolation for AppStore/OpenClaw helpers; ParamKeys.problems(_:_:); GatewayJSON nested literals; optional dictionary unwrapping. |
| `BotManagerOpenClawTests.swift`, `OpenClawSteerTests.swift` | SwarmHubCore imports; public stripEnvelope has signature (String) -> String, matching Array.map and Optional.map at the edited call sites; GatewayJSON.string is String?; fake gateway helpers and actor isolation retain the existing signatures. |

All 17 files are at most 500 lines; `HermesBackend.swift` is 461 and the new extension is 52. SwiftPM discovers the extension under Sources/AgentApp; scripts/build.sh also discovers all Swift sources with find. The extraction does not require project-file changes.

## Linux verification

Commands: `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`, then the same discovery with `-s scripts`, then all seven `Tests/Scripts/*-test.sh` suites under both `/bin/sh` and `/bin/dash` using their documented arguments and shell-selection environment variables. Baseline runs use a clean `git archive 749d826` under the writable workspace. All runs are sequential to avoid smoke-test interference from shared temporary fixtures.

| Check | Current worktree | Base `749d826` |
| --- | --- | --- |
| sim Python | 437 tests; 8 failure records, 13 skips (409.040s) | 437 tests; identical 8 failure records and 13 skips (406.489s) |
| scripts Python | 56 tests; 5 errors | 56 tests; identical 5 errors |
| Shell cases, sh + dash | 158 passed, 0 failed; bot-msg suite skipped twice (exit 77, loopback denied) | Identical: 158 passed, 0 failed; same 2 skips |
| `git diff --check` | Passed, including all new files in the offline clone's staged diff | N/A |

The eight sim failure records reproduce on base:

- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: the outer sandbox denies a new top-level workspace directory in fallback mode.
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`: Node spawnSync reports EPERM.
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: user namespaces are unavailable; the launcher records fallback instead of namespaced.
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: socket send is denied.
- `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: four failing subtests, `rt_sigqueueinfo`, `rt_tgsigqueueinfo`, `kill`, `tgkill`, because user namespaces are unavailable.

The five scripts errors also reproduce on base: four `test_grokbot_server.FetchTests` cases (`test_exporter_merges_cache_and_reports_coverage_without_leaking_secrets`, `test_http_error_stops`, `test_pages_back_to_seq_one_with_blobs_and_omitted_rows`, `test_stop_leaves_previous_export_untouched`) cannot bind loopback sockets; `test_grokbot_server.ProtoAndCryptoTests.test_safe_storage_vector_from_openssl` requires the unavailable macOS `/usr/lib/system/libcommonCrypto.dylib`.

Shell case counts per shell: accounts 6, box-adopt 11, box-readings 12, claude-login 5, code-job 23, swarmhub-report 22. bot-msg runs no cases when its socket preflight skips.

Logs and JSON summaries are kept under `/tmp/sysprompt1-*` on this host. No model behavior or native Swift build is certified by these Linux checks.

## Commit environment limitation

The requested primary worktree's gitdir is `/home/ubuntu/work/swarmhub/peer-review/.git/worktrees/wt-sysprompt1`, outside the writable sandbox. `git add` fails with `Unable to create .../index.lock: Read-only file system`. Approval escalation is unavailable. The primary branch cannot be advanced here.

To preserve a reviewable commit, a local clone was created at `/tmp/sysprompt1-commit` with `git clone --no-hardlinks --single-branch --branch swarmhub/sysprompt1 . /tmp/sysprompt1-commit`. It uses no network and retains parent `10aaf25`. Delivery uses a commit on `swarmhub/sysprompt1` in that clone, exported as `/tmp/sysprompt1-review.bundle` and `/tmp/sysprompt1-review.patch`. The original worktree retains the changes for review; its Git HEAD remains `10aaf25`.
