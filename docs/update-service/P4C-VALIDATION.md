# P4c validation (Linux, 2026-10-20)

Branch `swarmhub/core-p4c`, base `1f1d463`. TEST keys and isolated fixtures only; no real boxes, update hosts,
production access or Hermes modifications. Python commands ran sequentially with `PYTHONDONTWRITEBYTECODE=1`.

| Command | Actual result |
| --- | --- |
| `python3 -m unittest discover -s Tests/Updater -p "test_*.py"` | 190 run: 168 passed, 22 errors opening loopback sockets |
| `python3 -m unittest discover -s scripts -p "test_*.py"` | 290 run: 285 passed, 1 skipped, 4 errors opening loopback sockets |
| `python3 -m unittest sim.test_remote_approvals` | 11 run, 11 passed |
| `python3 scripts/release/make_vectors.py --check` | byte-identical |
| `git diff --check 1f1d463` | passed |

The existing shell suites also ran sequentially under `/bin/sh` and `/bin/dash`: **79 cases passed under each
shell (158 total)**. Per shell: accounts-recipes 6, box-adopt 11, box-readings 12, claude-login 5, code-job 23,
swarmhub-report 22. `bot-msg-test.sh` skipped before running cases under both shells (exit 77: loopback sockets denied).

The 3 new `test_mac_code_confirm.MacCodeConfirm` tests passed both in isolation and in updater discovery. The actual
Mac version-bound command runs against the real launcher in temporary TEST-key updater prefixes. It verifies that
status/verify/check do not confirm, a confirmation writes only one box's state, N cannot confirm N+1, waiting data
lands with its code, and the Hermes stand-in remains byte-identical. Existing `Tests/Fixtures` remain byte-unchanged.

Loopback socket errors were `PermissionError: [Errno 1] Operation not permitted` in these existing tests:

```
test_fetch.Https.test_certificate_is_verified
test_fetch.Transport.test_body_and_headers
test_fetch.Transport.test_deadline_bounds_a_whole_file
test_fetch.Transport.test_http_errors_and_unreachable_hosts
test_fetch.Transport.test_only_allowlisted_https_origins
test_fetch.Transport.test_redirects_stay_on_the_allowlist
test_fetch.Transport.test_size_caps
test_fetch.Transport.test_slow_host_times_out
test_pull.Acceptance.test_bad_signature_keeps_last_good
test_pull.Acceptance.test_expired_index_reports_stale_and_leaves_the_runtime
test_pull.Acceptance.test_host_down_changes_nothing
test_pull.Acceptance.test_mirror_replay_of_an_old_index_is_rejected
test_pull.Acceptance.test_redirect_to_another_host_is_refused
test_pull.Acceptance.test_rollout_percent_is_honoured_deterministically
test_pull.Acceptance.test_tampered_blob_keeps_last_good
test_pull.Hermes.test_hermes_files_stay_byte_identical
test_pull.Hermes.test_installed_hermes_inside_and_outside_the_range
test_pull.Hermes.test_line_with_a_hermes_range_needs_a_known_hermes
test_pull.Hermes.test_unknown_hermes_skips_ranged_components_and_applies_the_rest
test_pull.Hermes.test_version_is_read_as_text_never_executed
test_pull.Pull.test_origins_come_from_config_and_none_configured_changes_nothing
test_pull.Pull.test_pull_applies_data_parks_code_and_sends_no_store
test_grokbot_server.FetchTests.test_exporter_merges_cache_and_reports_coverage_without_leaking_secrets
test_grokbot_server.FetchTests.test_http_error_stops
test_grokbot_server.FetchTests.test_pages_back_to_seq_one_with_blobs_and_omitted_rows
test_grokbot_server.FetchTests.test_stop_leaves_previous_export_untouched
```

Swift cannot build on this Linux host. Twelve new `BoxUpdateStateTests.swift` tests are authored and reviewed by
reading, but have **not run**. P4c remains pending Mac verification. On the MacBook run, sequentially:

```
swift test
swift test --package-path Packages/SwarmHubCore
scripts/test-ios-core.sh
```

The AgentApp run must include `BoxUpdateStateTests.swift`, `StagedInstallTests.swift`, `RenderGoldenTests.swift`,
`ManagedRemoteControlTests.swift`, skill-install/all-bots tests and the existing shell-suite wrappers. New coverage
includes per-box/version clicks, waiting components, exact native tool commands and IDs, separate status read-back,
failed/stale/model-only success refusal, version-change observation, single flight and namespaced cleanup,
persisted regression, absent bootstrap record, unavailable update source, direct chat routing and unreachable box.
