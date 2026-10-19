# MACFIX5 report

The Mac log identifies a recursive expansion of `require(_:_:sourceLocation:)` at
`Tests/AgentAppTests/ManagedActionsTests.swift:102`. The optional `input` was
unwrapped by `#require` inside another `#require` that checks the JSON dictionary
cast. The input unwrap now has its own statement; the JSON cast still uses
`#require`, and the fingerprint and gate assertions are unchanged.

The scan of every Swift file under `Tests/` and `Sources/` found 30 nested
assertion macro calls in 18 test files: the reported `#require` inside `#require`
and 29 `#require` calls inside `#expect` arguments. Each required value is now
unwrapped before the enclosing assertion. Immutable values shared by adjacent
assertions are reused; values parsed from mutated fixtures are unwrapped again
after each mutation. Assertion conditions, expected values, and messages are
preserved. No application code changed.

Validation:

- Scanned all 642 Swift files using a delimiter-aware static scanner that handles
  multiline calls, comments, quoted/raw/multiline strings, and interpolation.
  No nested `#require` or `#expect` remains in macro arguments.
- Every changed Swift file retains its original number of `#expect` calls.
- Reviewed the full diff; `git diff --check` passes.
- No Swift toolchain is installed here, so `swift build && swift test` could not
  be run. The changes require verification on the Mac.
- No commit was created. The pre-existing untracked `.json` file was left alone.

Full code diff:

```diff
diff --git a/Tests/AgentAppTests/AccountsTests.swift b/Tests/AgentAppTests/AccountsTests.swift
index 57f0c58..8c2c6bd 100644
--- a/Tests/AgentAppTests/AccountsTests.swift
+++ b/Tests/AgentAppTests/AccountsTests.swift
@@ -46,7 +46,8 @@ private let loggedIn = #"{"op":"accounts","claude":{"installed":true,"version":"
     let template = try #require(BotManagerText.recipe(.accounts))
     let status = try #require(CodingAccounts.statusInstructions(template: template))
     #expect(status.contains(#"op:"accounts""#) && status.contains("swarmhub block"))
-    #expect(try #require(CodingAccounts.installInstructions(template: template)).contains("npm install -g --prefix ~/.local @anthropic-ai/claude-code @openai/codex"))
+    let install = try #require(CodingAccounts.installInstructions(template: template))
+    #expect(install.contains("npm install -g --prefix ~/.local @anthropic-ai/claude-code @openai/codex"))
     let codex = try #require(CodingAccounts.loginInstructions(.codex, template: template))
     #expect(codex.contains("T=codex;") && codex.contains("background process") && !codex.contains("<tool>") && !codex.contains("SWARMHUB_EOF"))
     #expect(CodingAccounts.loginInstructions(.claude, template: template, script: nil) == nil, "Claude needs the script")
@@ -58,7 +59,8 @@ private let loggedIn = #"{"op":"accounts","claude":{"installed":true,"version":"
     #expect(code.contains("swarmhub-claude-login code 'good-code#st8'") && code.contains("Never repeat"))
     for bad in ["short", "has space here", "quote'here12", "semi;colon12", "$(reboot)xyz"] { #expect(CodingAccounts.codeInstructions(bad, template: template) == nil, "\(bad)") }
     #expect(CodingAccounts.logoutInstructions(.chatgpt, template: template) == nil, "the pool is shared by every bot: no log out")
-    #expect(try #require(CodingAccounts.logoutInstructions(.codex, template: template)).contains("case codex in"))
+    let logout = try #require(CodingAccounts.logoutInstructions(.codex, template: template))
+    #expect(logout.contains("case codex in"))
 }
 
 // MARK: State machine
diff --git a/Tests/AgentAppTests/ArtifactAccessTests.swift b/Tests/AgentAppTests/ArtifactAccessTests.swift
index 999b3bd..e0d65d9 100644
--- a/Tests/AgentAppTests/ArtifactAccessTests.swift
+++ b/Tests/AgentAppTests/ArtifactAccessTests.swift
@@ -85,7 +85,8 @@ import Testing
     #expect(await HeadlessSetup.render(to: directory, only: "p38", output: { lines.append($0) }) == 0, "\(lines)")
     for name in HeadlessP38Shots.names {
         let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
-        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
+        let bitmap = try #require(NSBitmapImageRep(data: data))
+        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
     }
     #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38Shots.names.count, "only the P38 shots")
 }
diff --git a/Tests/AgentAppTests/BotWorkTests.swift b/Tests/AgentAppTests/BotWorkTests.swift
index 2f2b943..d54bd56 100644
--- a/Tests/AgentAppTests/BotWorkTests.swift
+++ b/Tests/AgentAppTests/BotWorkTests.swift
@@ -220,5 +220,6 @@ final class WorkClock: @unchecked Sendable {
                        key: .init(bot: infra.id, target: "swarmhub-from-grok-jarvis"), start: clock.now)
     #expect(infra.messages.last?.isStreaming == true && !store.isWorking(infra))
     #expect(!store.isStreamingIn(infra), "the recipient's own chat still reconciles while the card is live")
-    #expect(HistoryReconciler.LocalRow(try #require(infra.messages.last)).isTextTurn == false, "never paired with the main session's turns")
+    let message = try #require(infra.messages.last)
+    #expect(HistoryReconciler.LocalRow(message).isTextTurn == false, "never paired with the main session's turns")
 }
diff --git a/Tests/AgentAppTests/BoxReadingsStoreTests.swift b/Tests/AgentAppTests/BoxReadingsStoreTests.swift
index 484368c..77bdfd8 100644
--- a/Tests/AgentAppTests/BoxReadingsStoreTests.swift
+++ b/Tests/AgentAppTests/BoxReadingsStoreTests.swift
@@ -87,7 +87,8 @@ private func turns(_ host: String) -> [(input: String, instructions: String)] {
     try await waitUntil { !store.anyTurnRunning && store.boxReadings(on: target).capacity?.slots == 2 }
     #expect(turns(chat).allSatisfy { $0.instructions.contains("( N=2; D=~/.hermes/swarmhub;") })
     #expect(jarvis.messages.first?.content == "Let this box run 2 coding jobs at a time." && store.managementExchanges[jarvis.id] == nil, "the block closes the exchange")
-    #expect(BoxCapacity(try #require(store.boxReadings(on: target).capacity)).line.hasSuffix("2 coding jobs at a time (set by you)"))
+    let capacity = try #require(store.boxReadings(on: target).capacity)
+    #expect(BoxCapacity(capacity).line.hasSuffix("2 coding jobs at a time (set by you)"))
 }
 
 @Test @MainActor func modelLogDoneAlsoRequestsModels() async throws {
diff --git a/Tests/AgentAppTests/ConcurrentTurnsTests.swift b/Tests/AgentAppTests/ConcurrentTurnsTests.swift
index a8ef876..92362e9 100644
--- a/Tests/AgentAppTests/ConcurrentTurnsTests.swift
+++ b/Tests/AgentAppTests/ConcurrentTurnsTests.swift
@@ -225,7 +225,8 @@ private let skill = BundledSkill(name: "swarmhub-chat", version: SkillVersion("1
     #expect(await HeadlessSetup.render(to: directory, only: "p39", output: { lines.append($0) }) == 0, "\(lines)")
     for name in HeadlessP39Shots.names {
         let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
-        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
+        let bitmap = try #require(NSBitmapImageRep(data: data))
+        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
     }
     #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP39Shots.names.count, "only the P39 shots")
 }
diff --git a/Tests/AgentAppTests/ConnectedAppsInstallTests.swift b/Tests/AgentAppTests/ConnectedAppsInstallTests.swift
index 22bd294..2de7110 100644
--- a/Tests/AgentAppTests/ConnectedAppsInstallTests.swift
+++ b/Tests/AgentAppTests/ConnectedAppsInstallTests.swift
@@ -110,7 +110,8 @@ private func swarmHub(provision: @escaping @Sendable () -> (Int, Any) = { (200,
     let (composio, session) = MockHermesProtocol.serve(composioHandler)
     let apps = ConnectedAppsStore(directory: temporaryStore().deletingLastPathComponent(), keyStore: keys, session: session, apiURL: URL(string: "https://\(composio)/api/v3.1/")!, provisioner: provisioner)
     #expect(await apps.connect("gmail") == nil && apps.retryToolkit == "gmail")
-    #expect(await apps.connect(try #require(apps.retryToolkit)) != nil)
+    let retryToolkit = try #require(apps.retryToolkit)
+    #expect(await apps.connect(retryToolkit) != nil)
     #expect(apps.retryToolkit == nil && apps.error == nil && apps.hasKey)
 }
 
diff --git a/Tests/AgentAppTests/ImportedSkillInstallTests.swift b/Tests/AgentAppTests/ImportedSkillInstallTests.swift
index 0574c72..48c2179 100644
--- a/Tests/AgentAppTests/ImportedSkillInstallTests.swift
+++ b/Tests/AgentAppTests/ImportedSkillInstallTests.swift
@@ -71,9 +71,11 @@ private func sentInstructions(_ host: String) -> [String] {
     let block = "```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"travel\",\"skills\":[{\"name\":\"getting-started\",\"version\":\"1.0.0\"}]}\n```"
     let (store, _, travel, host) = importedStore(replies: [block])
     #expect(store.importedSkills(for: travel).map(\.name) == ["Travel Planner", "Getting started"])
-    #expect(store.installImportedSkill(try #require(travel.gettingStartedSkill), on: travel))
+    let skill = try #require(travel.gettingStartedSkill)
+    #expect(store.installImportedSkill(skill, on: travel))
     try await waitUntil { !store.anyTurnRunning && travel.gettingStartedSkill?.isEnabled == true }
-    #expect(try #require(sentInstructions(host).first).contains("skills/imported/getting-started/SKILL.md"))
+    let instructions = try #require(sentInstructions(host).first)
+    #expect(instructions.contains("skills/imported/getting-started/SKILL.md"))
     #expect(travel.importedSkills[0].isEnabled == false)
 }
 
diff --git a/Tests/AgentAppTests/ManagedActionsTests.swift b/Tests/AgentAppTests/ManagedActionsTests.swift
index 20c1d69..dfed73d 100644
--- a/Tests/AgentAppTests/ManagedActionsTests.swift
+++ b/Tests/AgentAppTests/ManagedActionsTests.swift
@@ -99,7 +99,8 @@ private func runtimeRecord(status: String = "awaiting-coordinator", decided: Boo
     store.managedControl = { _, verb, task, input in
         #expect(task == taskID)
         if verb == "decide" {
-            let payload = try #require(try JSONSerialization.jsonObject(with: try #require(input)) as? [String: Any])
+            let input = try #require(input)
+            let payload = try #require(try JSONSerialization.jsonObject(with: input) as? [String: Any])
             #expect(payload["fingerprint"] as? String == record.fingerprint)
             #expect(payload["gate"] as? String == record.gate)
             runtime = runtimeRecord(status: "queued", decided: true)
diff --git a/Tests/AgentAppTests/ModelRecipeRefreshTests.swift b/Tests/AgentAppTests/ModelRecipeRefreshTests.swift
index 632c66c..557c00d 100644
--- a/Tests/AgentAppTests/ModelRecipeRefreshTests.swift
+++ b/Tests/AgentAppTests/ModelRecipeRefreshTests.swift
@@ -42,7 +42,8 @@ private func steps(_ previews: String?...) -> [ToolStep] { previews.map { ToolSt
     // The turn's own feature check reads capabilities once; the refresh adds one read per bot.
     try await waitUntil { !store.anyTurnRunning && capabilityReads(host) >= 3 }
     #expect(!reads(host).contains { $0.hasSuffix("/v1/skills") }, "skills are not read")
-    #expect(store.refreshModelsAfterRecipe(try #require(jarvis.messages.last), from: jarvis, in: jarvis).map(\.id) == [jarvis.id, mira.id])
+    let reply = try #require(jarvis.messages.last)
+    #expect(store.refreshModelsAfterRecipe(reply, from: jarvis, in: jarvis).map(\.id) == [jarvis.id, mira.id])
 }
 
 @Test @MainActor func anOrdinaryReplyRefreshesNothing() async throws {
diff --git a/Tests/AgentAppTests/OpenClawIdentityTests.swift b/Tests/AgentAppTests/OpenClawIdentityTests.swift
index 85f810d..53763fc 100644
--- a/Tests/AgentAppTests/OpenClawIdentityTests.swift
+++ b/Tests/AgentAppTests/OpenClawIdentityTests.swift
@@ -24,11 +24,14 @@ private let nodeV2Signature = "9cCfRKUG1ts7z_aNshv0je9U0lyrV-nfYcqzIKWxZhnXiHUML
     #expect(DeviceAuthPayload.v3(vectorFields) == expectedV3)
     #expect(DeviceAuthPayload.v2(vectorFields) == expectedV2)
     let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try #require(Base64URL.decode(identity.publicKey)))
-    #expect(publicKey.isValidSignature(try #require(Base64URL.decode(nodeV3Signature)), for: Data(expectedV3.utf8)), "Node's v3 signature verifies")
-    #expect(publicKey.isValidSignature(try #require(Base64URL.decode(nodeV2Signature)), for: Data(expectedV2.utf8)), "Node's v2 signature verifies")
-    #expect(!publicKey.isValidSignature(try #require(Base64URL.decode(nodeV3Signature)), for: Data(expectedV2.utf8)))
+    let decodedV3Signature = try #require(Base64URL.decode(nodeV3Signature))
+    #expect(publicKey.isValidSignature(decodedV3Signature, for: Data(expectedV3.utf8)), "Node's v3 signature verifies")
+    let decodedV2Signature = try #require(Base64URL.decode(nodeV2Signature))
+    #expect(publicKey.isValidSignature(decodedV2Signature, for: Data(expectedV2.utf8)), "Node's v2 signature verifies")
+    #expect(!publicKey.isValidSignature(decodedV3Signature, for: Data(expectedV2.utf8)))
     let ours = try identity.sign(expectedV3)
-    #expect(publicKey.isValidSignature(try #require(Base64URL.decode(ours)), for: Data(expectedV3.utf8)), "our own signature verifies")
+    let decodedOurs = try #require(Base64URL.decode(ours))
+    #expect(publicKey.isValidSignature(decodedOurs, for: Data(expectedV3.utf8)), "our own signature verifies")
     #expect(!ours.contains("=") && !ours.contains("+") && !ours.contains("/"), "base64url without padding")
 }
 
diff --git a/Tests/AgentAppTests/RoutineWatchTests.swift b/Tests/AgentAppTests/RoutineWatchTests.swift
index ade69e2..22657d9 100644
--- a/Tests/AgentAppTests/RoutineWatchTests.swift
+++ b/Tests/AgentAppTests/RoutineWatchTests.swift
@@ -52,11 +52,14 @@ private final class SleepGate: @unchecked Sendable {
     let manual = try #require(HermesJob.parse(row))
     #expect(manual.manualRunAt == "2026-10-15T20:03:01+02:00" && RoutineWatch.serverSaysRunning(manual))
     row["last_run_at"] = "2026-10-15T20:06:30+02:00"
-    #expect(!RoutineWatch.serverSaysRunning(try #require(HermesJob.parse(row))), "a manual run older than the last run is over")
+    let finished = try #require(HermesJob.parse(row))
+    #expect(!RoutineWatch.serverSaysRunning(finished), "a manual run older than the last run is over")
     row["manual_run_at"] = NSNull(); row["fire_claim"] = ["owner": "scheduler-1", "claimed_at": "2026-10-15T20:03:02+02:00"]
-    #expect(try #require(HermesJob.parse(row)).fireClaimed)
+    let claimed = try #require(HermesJob.parse(row))
+    #expect(claimed.fireClaimed)
     row["fire_claim"] = NSNull()
-    #expect(!(try #require(HermesJob.parse(row))).fireClaimed)
+    let unclaimed = try #require(HermesJob.parse(row))
+    #expect(!unclaimed.fireClaimed)
 }
 
 @Test @MainActor func aBotsCronStepRefreshesItsRoutines() async throws {
diff --git a/Tests/AgentAppTests/RoutinesTests.swift b/Tests/AgentAppTests/RoutinesTests.swift
index 378e3be..c3c8545 100644
--- a/Tests/AgentAppTests/RoutinesTests.swift
+++ b/Tests/AgentAppTests/RoutinesTests.swift
@@ -180,7 +180,8 @@ import Testing
     #expect(RoutineTime.isLater("2026-10-13T09:00:06.5+02:00", than: "2026-10-13T08:59:00+02:00"))
     #expect(!RoutineTime.isLater("2026-10-13T08:00:00+02:00", than: "2026-10-13T09:00:00+02:00"))
     #expect(RoutineTime.isLater("2026-10-13T08:00:00+02:00", than: ""))
-    #expect(RoutineTime.relative("2026-10-13T09:00:00+00:00", now: try #require(RoutineTime.date("2026-10-13T11:00:00+00:00"))) == "2 hours ago")
+    let now = try #require(RoutineTime.date("2026-10-13T11:00:00+00:00"))
+    #expect(RoutineTime.relative("2026-10-13T09:00:00+00:00", now: now) == "2 hours ago")
 
     var interval = jobPayload(id: "0123456789ab", name: "Pulse", enabled: false)
     interval["schedule"] = ["kind": "interval", "minutes": 30, "display": "every 30m"]
diff --git a/Tests/AgentAppTests/TeamAppReviewTests.swift b/Tests/AgentAppTests/TeamAppReviewTests.swift
index c4ce082..012ef4c 100644
--- a/Tests/AgentAppTests/TeamAppReviewTests.swift
+++ b/Tests/AgentAppTests/TeamAppReviewTests.swift
@@ -20,7 +20,8 @@ import Testing
         store.connectedApps.localApprovals[approval.id] = .chat
         let first = try #require(store.teamAppReview(approval, bot: bot))
         approval.command = #"{"app":"fixture","tool":"FIXTURE_READ","account":"fixture-account","arguments":{"target":"b"}}"#
-        #expect(try #require(store.teamAppReview(approval, bot: bot)).2 != first.2)
+        let changed = try #require(store.teamAppReview(approval, bot: bot))
+        #expect(changed.2 != first.2)
         approval.command = #"{"app":"fixture","tool":"FIXTURE_READ","account":"different-account","arguments":{"target":"a"}}"#
         #expect(store.teamAppReview(approval, bot: bot) == nil)
         approval.command = #"{"app":"fixture","tool":"FIXTURE_WRITE","account":"fixture-account","arguments":{"target":"a"}}"#
diff --git a/Tests/AgentAppTests/TeamCoordinationTests.swift b/Tests/AgentAppTests/TeamCoordinationTests.swift
index 33db5e6..f4090b2 100644
--- a/Tests/AgentAppTests/TeamCoordinationTests.swift
+++ b/Tests/AgentAppTests/TeamCoordinationTests.swift
@@ -36,8 +36,9 @@ import SwarmHubCoordination
         let (store, _, id) = try WorkflowInteractionTests().fixture()
         store.authorizeTeamWorkflow(id)
         store.bots[1].hermesProfile = "another-profile"
-        #expect(store.workflowMembers(try #require(store.workflows[id])).count == 1)
-        #expect(store.teamPolicyProblem(try #require(store.workflows[id]), botID: store.bots[1].id) != nil)
+        let workflow = try #require(store.workflows[id])
+        #expect(store.workflowMembers(workflow).count == 1)
+        #expect(store.teamPolicyProblem(workflow, botID: store.bots[1].id) != nil)
     }
 
     @Test func anotherDeviceCannotTakeOverByReauthorizing() throws {
@@ -106,9 +107,12 @@ import SwarmHubCoordination
     @Test func quietHoursUseLocalCivilTimeAcrossDST() throws {
         var reporting = TeamReporting(); reporting.timeZoneID = "Europe/Warsaw"; reporting.quietStartMinute = 22 * 60; reporting.quietEndMinute = 8 * 60
         let parser = ISO8601DateFormatter()
-        #expect(reporting.isQuiet(at: try #require(parser.date(from: "2026-10-25T00:30:00Z"))))
-        #expect(reporting.isQuiet(at: try #require(parser.date(from: "2026-10-25T01:30:00Z"))))
-        #expect(!reporting.isQuiet(at: try #require(parser.date(from: "2026-10-25T07:00:00Z"))))
+        let beforeFallback = try #require(parser.date(from: "2026-10-25T00:30:00Z"))
+        #expect(reporting.isQuiet(at: beforeFallback))
+        let afterFallback = try #require(parser.date(from: "2026-10-25T01:30:00Z"))
+        #expect(reporting.isQuiet(at: afterFallback))
+        let morning = try #require(parser.date(from: "2026-10-25T07:00:00Z"))
+        #expect(!reporting.isQuiet(at: morning))
     }
 
     @Test func speechUsesOnlyTheFinishedRealReply() {
diff --git a/Tests/AgentAppTests/TeamRecoveryTests.swift b/Tests/AgentAppTests/TeamRecoveryTests.swift
index abf482e..ad092fc 100644
--- a/Tests/AgentAppTests/TeamRecoveryTests.swift
+++ b/Tests/AgentAppTests/TeamRecoveryTests.swift
@@ -46,7 +46,9 @@ actor TeamRecoveryBackend: AgentBackend {
         #expect(store.workflows[id]?.tasks[0].delivery?.state == .uncertain)
         await store.recoverTeams()
         #expect(await backend.count() == 1, "Missing history cannot justify a resend")
-        #expect(!store.canReassignWorkflowTask(try #require(store.workflows[id]), task: try #require(store.workflows[id]?.tasks[0])))
+        let workflow = try #require(store.workflows[id])
+        let task = try #require(store.workflows[id]?.tasks[0])
+        #expect(!store.canReassignWorkflowTask(workflow, task: task))
         await backend.finishRemote()
         await store.recoverTeams()
         try await waitUntil { store.workflows[id]?.state == .completed }
diff --git a/Tests/AgentAppTests/TeamViewTests.swift b/Tests/AgentAppTests/TeamViewTests.swift
index c482691..5a754d9 100644
--- a/Tests/AgentAppTests/TeamViewTests.swift
+++ b/Tests/AgentAppTests/TeamViewTests.swift
@@ -10,7 +10,8 @@ import Testing
         #expect(await HeadlessSetup.render(to: directory, only: "team", output: { _ in }) == 0)
         for name in ["team-uncertain", "team-project-context"] {
             let data = try Data(contentsOf: directory.appending(path: name + ".png"))
-            #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000)
+            let bitmap = try #require(NSBitmapImageRep(data: data))
+            #expect(bitmap.pixelsWide > 0 && data.count > 4_000)
         }
     }
 }
diff --git a/Tests/AgentAppTests/WorkflowInteractionTests.swift b/Tests/AgentAppTests/WorkflowInteractionTests.swift
index 69ac6f3..b17be61 100644
--- a/Tests/AgentAppTests/WorkflowInteractionTests.swift
+++ b/Tests/AgentAppTests/WorkflowInteractionTests.swift
@@ -229,7 +229,8 @@ actor ReportThenDisconnectBackend: AgentBackend {
     #expect(await HeadlessSetup.render(to: directory, only: "p38e", output: { lines.append($0) }) == 0, "\(lines)")
     for name in HeadlessP38EShots.names {
         let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
-        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
+        let bitmap = try #require(NSBitmapImageRep(data: data))
+        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
     }
     #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38EShots.names.count, "only the P38 E shots")
 }
diff --git a/Tests/AgentAppTests/WorkflowTests.swift b/Tests/AgentAppTests/WorkflowTests.swift
index b6b43fb..57d35d5 100644
--- a/Tests/AgentAppTests/WorkflowTests.swift
+++ b/Tests/AgentAppTests/WorkflowTests.swift
@@ -192,7 +192,8 @@ import Testing
     #expect(await HeadlessSetup.render(to: directory, only: "p38d", output: { lines.append($0) }) == 0, "\(lines)")
     for name in HeadlessP38DShots.names {
         let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
-        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
+        let bitmap = try #require(NSBitmapImageRep(data: data))
+        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
     }
     #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38DShots.names.count, "only the P38 D shots")
 }
```
