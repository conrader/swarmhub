Implemented B1–B3 and M1–M5 in SwarmHub only. No live replay, real outbound, provisioning, deployment, gateway restart, Hermes modification, source-auth write, or commit was performed. Tests use synthetic credentials and fake outbound operations.

| Finding | Change | Regression tests |
|---|---|---|
| B1 | Verifiers and harness rebuilds run with a scrubbed environment, workspace/private-temp filesystem access and no network. Linux requires Landlock ABI 3+ and libseccomp; macOS uses sandbox-exec. Missing isolation refuses execution. Extra authority requires a separate owner-gated operation. | `test_B1_admitted_code_job_cannot_execute_host_verification`; `test_B1_outside_write_from_verify_command_is_denied`; `test_B1_edited_test_cannot_write_outside_or_read_host_secret`; `test_B1_network_from_command_and_edited_test_is_denied`; environment/symlink and unsupported-platform tests. |
| B2 | Generate minimal OpenAI QA configuration instead of copying source configuration. Remove connectors/apps, writable roots, tool network access and inherited secrets/proxies/startup settings from discovery and both harness entrypoints. Authentication alone is copied privately. | `test_B2_unsafe_source_config_and_environment_capabilities_are_removed`. |
| B3 | Added structured `swarmctl control get/decide`. Cards display the runtime spec, including exact argv, recipient/content, coding parameters and risks. Decisions atomically check fingerprint, gate and deciding role. Fence-built cards cannot approve anything. | `test_B3_decision_rejects_wrong_fingerprint_or_gate`; `test_B3_structured_control_returns_immutable_operation_B`; Swift `aFenceDescribingActionAForTaskBDisplaysOnlyRuntimeBAndCannotApproveA`. |
| M1 | Resolve verifier defaults before admission/fingerprinting; explicitly store/pass an empty verifier when disabled. Managed execution never consults mutable defaults. | `test_M1_owner_gated_verifier_is_frozen_before_defaults_change`; `test_M1_explicit_no_verifier_ignores_environment_fallback`. |
| M2 | Persist separate pending cards; finalize audits/remove cards only after a matching runtime receipt. Query before retry, retain failed/unexecuted decisions and prevent concurrent duplicate requests. Direct runtime decisions replace bot decision turns. | Swift `failedOrUnexecutedManagedDecisionsKeepRetryableCards`; `staleManagedRecordCannotBeApprovedAndPendingSurvivesPersistence`; `missingControlInterfaceNeverMakesAModelFenceAnApproval`. |
| M3 | Swift and Python share `~/.hermes/swarmhub/secrets`; retain atomic 0600 writes and separate remote-host intake. | `test_M3_swift_shared_intake_path_passes_real_provision_validator`; Swift `swiftSecretWriterHandsOffToTheRealPythonProvisioningValidator` executes the actual writer and Python validator together. |
| M4 | General goals accept chat deliverables/references. Explicit `/goal --coding <text>` retains commit-or-tests plus report requirements. | Swift `nonCodingAndReadOnlyGoalsCompleteWithChatDeliverables`; `goalEvidenceFollowsExplicitTypeAndRejectsPlaceholders`. |
| M5 | ExitStack owns temporary credentials from creation, including constructor failures. Quiesce writers before exporting; independently attempt process/server/session cleanup and delete credentials even after export/cleanup errors. Preserve partial-record diagnostics. | `test_M5_export_failure_cannot_skip_process_session_or_credential_cleanup`; `test_M5_initialization_failure_after_credential_copy_cleans_tree`; `test_M5_server_and_session_cleanup_failures_still_delete_credentials`; `test_M5_server_close_runs_when_shutdown_fails`; `test_M5_partial_cli_record_does_not_abort_export`. |

Validation: `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **156 tests, 155 passed, 1 skipped**, including **17 new Python regressions**. Completion cases 17–22: **6 passed under sh, 6 under dash**. Both bot-msg socket suites returned **77 / SKIP** because loopback binds are prohibited here. `git diff --check` passed. Skill packaging/version expectations include the new sandbox helper (coding 1.3.3, messages 1.3.4).

macOS verification remains: compile/run Swift tests (7 new test functions), verify the installed profile-local control path and approval persistence/receipts, run the Swift-writer/Python-validator handoff, and exercise sandbox-exec filesystem/network denials and cancellation. Approval control currently supports a runtime on the same Mac through its installed SwarmHub skill; remote-host notifications fail closed and require a trusted control transport before approval can be enabled. This replaces the unsafe model-mediated path deliberately. The live harness still does not establish native app behavior or ordinary protected `.git` commit behavior. No live pass 9 was run.

Exact live pass 9 command, for a plain box Bash shell with a fresh output directory:

```bash
cd /home/box/work/swarmhub/wt-peer
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
PATH="/home/box/.npm-global/bin:$PATH" \
QA_CLI_EXECUTION_PATH='plain box shell; workspace-write CLI; sandboxed verification; minimal QA config' \
python3 -B sim/live_managed.py \
  --usage-db /workspace/ermes/qa-swarmhub/home/state.db \
  --output sim/results/live-9
```

Results: Python 155 passed, 1 skipped; completion 12 passed; bot-msg 2 suites skipped; Swift 7 new tests unrun; diff check passed.
