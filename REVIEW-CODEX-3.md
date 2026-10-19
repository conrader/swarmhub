# Code review: managed runtime and delivery

Reviewed `5b3c4f7..73463a681551eb104a15b56ac29c2a11163f345c` (`swarmhub/peer-delivery`), 2026-10-19. Code was not modified. Checks used disposable local fixtures; no live model, gateway, connector, provisioning, or outbound operation was invoked.

Findings are ranked by release severity. “Blocker” means an execution or approval boundary is unsafe; “major” means a material correctness or secrets-lifecycle defect.

## Blockers

### B1. Automatic coding verification executes unrestricted host commands

**Location:** `Resources/Skills/swarmhub-coding/scripts/code-job:121–128`; admission at `Resources/Skills/swarmhub-messages/scripts/swarm_policy.py:176–177,201–203`.

A coding spec can supply any one-line shell program as `verify`. With no declared risks, admission assigns `gate=auto`. After the CLI produces a report, code-job executes that program with ordinary `/bin/sh`, outside the CLI's workspace sandbox. This also runs model-edited test/build code with host privileges. There is no outbound gate or network restriction at this execution point. A verification command can read credentials, modify another project, or invoke a real sender without an owner/coordinator decision. This uses the supported API; it does not require impersonating another profile or modifying the journal.

**Confirmed locally:** an admitted coding task with a synthetic CLI and `verify="printf executed > <file outside directory>"` had gate `auto`, wrote the outside marker, and finished `ok`. No network was used.

**Concrete fix:** run verification in an enforced sandbox with the task's explicit filesystem/network permissions and a scrubbed environment. Gate any requested additional authority before launch. Do not treat an approved test-command string as permission for arbitrary host access by the source it executes. Add negative tests for outside-workspace writes and outbound attempts from both the command and an edited test module.

### B2. The live harness copies production connector configuration and permissions into its “isolated” CLI

**Location:** `sim/live_cli.py:73–78`; consumers at `sim/live_managed.py:61–67` and `sim/live_cli_probe.py:39–40`.

`writable_cli_state` copies the complete operator `config.toml`, including any MCP server commands, connector credentials, extra writable roots, and network settings. Changing HOME and making a private copy protects the original file from writes; it does not remove the copied capabilities. The code-job invocation overrides only sandbox mode, approval policy, model, and effort (`code-job:273–274`). The harness checks Hermes's tool inventory, but never checks or restricts the nested CLI's connectors. The standalone probe additionally inherits the whole source environment. Thus “All outbound remains FAKE” is not an enforced property for the real CLI: configured tools or inherited permissions can reach production.

**Confirmed locally:** a synthetic config containing a production MCP command/token, `network_access=true`, and an outside writable root survived copying byte-for-byte. No connector was started.

**Concrete fix:** generate a minimal QA config from an allowlist, disable all connectors/apps/hooks and extra writable roots, explicitly deny tool network access, and use a minimal environment in both harness entrypoints. Supply only the authentication/provider settings required for the intended model call. Test with deliberately unsafe source configuration and verify those capabilities are absent from the effective child configuration, not merely that source files are unchanged.

### B3. Approval cards are not bound to the operation the runtime will execute

**Location:** `Sources/AgentApp/Models/ManagedActions.swift:65–70,87–96`; `Sources/AgentApp/Stores/AppStore+ManagedActions.swift:11–21,37–39`.

The card's kind, summary, draft, risks, and intent all come from model-authored JSON. The app never retrieves the corresponding immutable runtime spec. Clicking Approve sends only the task ID and actor; the runtime decides that ID and subsequently executes its stored argv. A mistaken or manipulated fence can describe a harmless read or different draft while naming a valid pending production/outbound task. The runtime's actor check does not detect this mismatch: the actual deciding profile is used, but the human approved different displayed content. The command preview shows `swarmctl decide`, not the underlying operation.

**Concrete fix:** fetch the authoritative pending record through a structured SwarmHub control interface, render its exact operation/recipient/content and risks, and bind the decision to its fingerprint and current gate. Reject stale or mismatched cards. Keep the model-authored fence as a notification only. Add a test where the fence describes action A but names action B, and ensure approval is refused. This can be implemented in SwarmHub without changing Hermes itself.

## Major findings

### M1. The verifier that runs can be absent from the immutable approved task

**Location:** `Resources/Skills/swarmhub-coding/scripts/code-job:50–52,85–91`; `Resources/Skills/swarmhub-messages/scripts/swarm_jobs.py:28–30`.

`check_job` compares the explicit `VERIFY_ARG` with `spec.get("verify", "")`. Only afterward, code-job resolves `CODE_JOB_VERIFY` or the current `coding.conf` default. A managed task without `verify` therefore passes the immutable-parameter check and executes a command that was never recorded or approved. A default changed while a task waits for approval or a slot changes the eventual operation. The launcher freezes order/model, but not verification.

**Confirmed locally:** submitted a coding task with no `verify` field, set an environment fallback, and observed that fallback create a marker while the stored spec still had no verifier.

**Concrete fix:** resolve and store the effective verifier during admission, include it in the fingerprint/approval, and pass it explicitly. Managed jobs must not consult mutable environment/config defaults at execution time. Distinguish an explicit “no verifier” from an unresolved default. Add a queued/owner-gated task test that changes defaults before launch.

### M2. A failed decision turn permanently suppresses the still-pending approval

**Location:** `Sources/AgentApp/Stores/AppStore+ManagedActions.swift:39–45`, with suppression at line 14. Test masking the problem: `Tests/AgentAppTests/ManagedActionsTests.swift:107–113`.

As soon as `send` accepts or queues the bot turn, the app removes the card and audits it as approved/denied. This does not establish that `swarmctl decide` ran. A disconnected/stopped turn, missing skill, CLI error, or model reply without execution leaves the runtime action awaiting a decision. Any later fence for that task is discarded because the audit already contains a final decision. The bot's queue can remain blocked with no usable retry card. The test explicitly expects permanent suppression after the scripted backend returns the original approval fence; it never executes a runtime decision.

**Concrete fix:** persist a separate `decisionPending` state and reconcile it against an authoritative runtime receipt. Finalize the audit and remove the card only after the runtime confirms the decision. On failure, restore the card; on uncertain acknowledgement, query status before retrying. Test transport failure, command rejection, and a reply that never invokes the command.

### M3. Secret files produced by the Swift sheet cannot be used by the provisioning hook, even on the same Mac

**Location:** `Sources/AgentApp/Models/ManagedActions.swift:180–182`; rejecting check at `Resources/Skills/swarmhub-messages/scripts/swarm_intake.py:80–87`, used by `swarm_policy.py:223–226`.

The sheet writes under `~/Library/Application Support/SwarmHub/secrets`. The runtime accepts secret references only when their parent resolves to `~/.hermes/swarmhub/secrets`. A correctly owned, regular 0600 file returned by the sheet therefore fails the provisioning request's secret-field validation. The remote-host warning does not solve this same-host incompatibility. Swift tests verify the file and chat path; Python tests independently create a runtime intake file, so neither tests the actual handoff.

**Confirmed locally:** a synthetic 0600 file in the Swift-equivalent Application Support location was rejected by `is_intake_path`.

**Concrete fix:** use a shared intake location for same-host provisioning, or add a secure local import that returns a runtime-owned secret reference without exposing the value to the model. Keep separate remote-host intake. Add an integration test feeding a path produced by the Swift writer into the real Python provisioning validator.

### M4. Every goal now requires coding evidence, including non-coding goals

**Location:** `Sources/AgentApp/Models/ChatAutomation.swift:61–65,116–117`; `Sources/AgentApp/Stores/AppStore+Goals.swift:109–111,137–140`.

The new unconditional completion rule requires a commit or passing tests plus a file report for all `/goal` tasks. `GoalRun` has no coding-only discriminator. A completed research summary, explanation, or draft delivered in chat cannot truthfully satisfy this contract; the app asks for unrelated coding evidence and eventually blocks it. Bots without file/test tools cannot finish even when they have delivered everything requested. Updating every successful test fixture to include a synthetic commit/report hides this regression.

**Concrete fix:** make evidence requirements depend on the goal's explicit acceptance criteria/type. Retain commit/test/report requirements for applicable coding goals and accept task-appropriate deliverables for other goals. Add a non-coding completion regression and a read-only goal whose constraints forbid commits or unnecessary file creation.

### M5. Evidence-export failure can skip cleanup of copied real credentials and running jobs

**Location:** `sim/live_managed.py:225–227,531–563`; initialization and ownership at lines 54–65 and 580–589.

`finish()` exports evidence before stopping children or deleting private CLI state. Any export exception aborts the remaining cleanup. In particular, it parses every session JSONL line without handling a truncated last record, which can occur when entering cleanup after a live job fails or times out while the CLI is still writing. An I/O failure has the same result. The private directory now contains copies of real CLI authentication/configuration. Also, construction happens before the caller's `try/finally`, so a failure after credential copying but before `ManagedSuite.__init__` returns leaks the directory too.

**Confirmed locally:** injecting an export failure left a synthetic private auth file in place and skipped cleanup entirely. This probe used no real credentials.

**Concrete fix:** own the temporary tree with a context manager/ExitStack from creation onward. Put process termination, session cleanup, and deletion of credential copies in independent `finally` paths; evidence-export failure must not skip them. Quiesce writers before parsing transcripts and handle partial last records. Add failure-injection tests for export, initialization, and server cleanup.

## Verification and scope limits

- Targeted offline gap tests: **13 passed, 1 skipped** (`test_gaps*.py`). The socket test skipped because this sandbox forbids loopback binds.
- Offline live-harness tests: **27 passed** (`test_live_*.py`). These are unit tests, not live provider runs.
- Shell completion/verification cases 17–22: **6 passed** under `/bin/sh`.
- Independent disposable probes confirmed B1, configuration retention in B2, M1, M3, and the export-failure cleanup path in M5. Swift findings are source-reviewed; Swift/macOS is unavailable here.
- Passing fixtures do not close the identified gaps. The Swift approval fake checks dispatch, not runtime acknowledgement. The intake tests never cross the Swift/Python boundary. CLI-isolation tests check private copies and unchanged sources, not removed connector capabilities. The chain tests fabricate job fields and model replies (`sim/test_live_chains.py:48–85`). The live chain uses a harness-only action bridge and a writable `QA-git-store` layout (`sim/live_cli.py:98–124`); it does not establish native app execution or ordinary protected `.git` commit behavior. The reports disclose some of these limits, but their PASS totals are insufficient release evidence.
- The app's draft spec hard-codes `fake=true`, and the runtime skips execution for actual FAKE records. However, the runtime intentionally also has a real path: `swarm_policy.py:236–238` composes a configured outbound sender, and an approved non-FAKE action executes its argv in `swarm_jobs.py:134`. B1/B2 provide additional routes outside that FAKE record mechanism. No real send was attempted or observed in this review.
- A targeted scan of changed files found no private-key PEM blocks, long `sk-` provider-key forms, or JWTs. This is not proof that all possible secrets are absent. The atomic 0600 intake writes and symlink replacement are useful protections; they do not resolve the handoff/configuration/cleanup findings above.
- **Hermes itself:** no Hermes core/server/vendor implementation changes were found in this range. The changed `peer-runtime.py` is SwarmHub-owned; its existing plugin installer only changes the emitted plugin version in this diff. The live harness invokes external SwarmHub hook/action bridges and does not install them into Hermes. No installer, gateway restart, or Hermes mutation was performed during this review.
- `git diff --check 5b3c4f7..HEAD` reports trailing whitespace in six archived QA logs; this is cosmetic and not a release-driving finding. No additional minor finding warrants elevation over the issues above.

## Release verdict

**Not fit to release.** Resolve B1–B3 before enabling these paths, fix the major correctness/secrets-lifecycle issues, and verify the Swift-to-runtime approval and secret handoffs on macOS. The current passing simulation totals do not establish safe outbound isolation or correct end-to-end user decisions. All proposed fixes can remain within SwarmHub; changing Hermes itself is neither required nor authorized.
