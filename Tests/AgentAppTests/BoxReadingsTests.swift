import Foundation
import Testing
@testable import AgentApp

// P31 D+E pure parts: the `models` and `box_capacity` ops (good, hostile, oversize), the capacity computation and its
// advice table, the Coding model line, the coding model change and the turns' recipe text, and the recipe shell test
// under /bin/sh and /bin/dash. Synthetic only; nothing reaches a box.

private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

private func ops(_ json: String) -> [SwarmhubOp] { SwarmhubBlock.ops(in: "ok\n```swarmhub\n\(json)\n```") ?? [] }

private func models(_ json: String) -> [BotModels]? {
    if case .models(let rows)? = ops(json).first { rows } else { nil }
}

private func capacity(_ json: String) -> BoxCapacityReport? {
    if case .boxCapacity(let report)? = ops(json).first { report } else { nil }
}

private let goodCapacity = #"{"op":"box_capacity","cpus":2,"mem_total_mb":3891,"mem_avail_mb":1380,"disk_free_mb":17400,"load1":"0.42","slots":1,"jobs":[["2026-10-15T01:02:03Z",12,300,480,0]]}"#

// MARK: models

@Test func modelsOpKeepsGoodRowsAndTreatsMissingKeysAsEmpty() throws {
    let rows = try #require(models(#"{"op":"models","list":[{"name":"jarvis","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"","sub_provider":""},{"name":"default","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"gpt-6.1-sol","sub_provider":"openai-codex"},{"name":"mira","model":"grok-4.1"}]}"#))
    #expect(rows == [BotModels(name: "jarvis", model: "gpt-5.6-terra", provider: "openai-codex"),
                     BotModels(name: "default", model: "gpt-5.6-terra", provider: "openai-codex", subModel: "gpt-6.1-sol", subProvider: "openai-codex"),
                     BotModels(name: "mira", model: "grok-4.1", provider: "")])
    #expect(models(#"{"op":"models","list":[]}"#) == [])
    #expect(models(#"{"op":"models"}"#) == nil && models(#"{"op":"models","list":"jarvis"}"#) == nil)
}

@Test func modelsOpDropsHostileRows() throws {
    let rows = try #require(models(#"""
    {"op":"models","list":[
      {"name":"../etc","model":"m","provider":"p"}, {"name":"","model":"m","provider":"p"}, {"name":"a b","model":"m","provider":"p"},
      {"name":"x1","model":"gpt; rm -rf ~","provider":"p"}, {"name":"x2","model":"m","provider":"p\"q"}, {"name":"x3","model":"m","provider":"p","sub_model":"$(id)"},
      {"name":"x4","model":7,"provider":"p"}, {"name":"x5","model":"m","provider":"p","sub_provider":"\n"}, "row", 3,
      {"name":"ok","model":"openrouter/anthropic:claude-x.1","provider":"openrouter","sub_model":"","sub_provider":""},
      {"name":"ok","model":"second","provider":"p"}
    ]}
    """#))
    #expect(rows.map(\.name) == ["ok"] && rows[0].model == "openrouter/anthropic:claude-x.1", "the first row per name")
    let long = String(repeating: "m", count: 101)
    #expect(models(#"{"op":"models","list":[{"name":"a","model":"\#(long)","provider":"p"}]}"#) == [])
    #expect(BotModels.isValidID(String(repeating: "m", count: 100)) && BotModels.isValidID("") && !BotModels.isValidID("gpt 6"))
}

@Test func modelsOpIsCappedAt200Rows() throws {
    let rows = (0..<500).map { #"{"name":"b\#($0)","model":"m","provider":"p"}"# }.joined(separator: ",")
    let parsed = try #require(models(#"{"op":"models","list":[\#(rows)]}"#))
    #expect(parsed.count == BotModels.rowLimit && parsed.first?.name == "b0" && parsed.last?.name == "b199")
}

// MARK: box_capacity

@Test func capacityOpParsesTheProbeLine() throws {
    let report = try #require(capacity(goodCapacity))
    #expect(report.cpus == 2 && report.memTotalMB == 3891 && report.memAvailMB == 1380 && report.diskFreeMB == 17400 && report.load1 == "0.42" && report.slots == 1)
    #expect(report.jobs == [.init(at: try Date("2026-10-15T01:02:03Z", strategy: .iso8601), waited: 12, ran: 300, peakMB: 480, exit: 0)])
    #expect(capacity(goodCapacity.replacingOccurrences(of: #""slots":1"#, with: #""slots":null"#))?.slots == nil)
    #expect(capacity(goodCapacity.replacingOccurrences(of: #""slots":1"#, with: #""slots":0"#))?.slots == nil, "0 is code-job's default: not set")
}

@Test func capacityOpRefusesNumbersOutOfRange() {
    for (from, to) in [(#""cpus":2"#, #""cpus":0"#), (#""cpus":2"#, #""cpus":"2""#), (#""cpus":2"#, #""cpus":2.5"#), (#""cpus":2"#, #""cpus":true"#),
                       (#""mem_avail_mb":1380"#, #""mem_avail_mb":5000"#), (#""mem_total_mb":3891"#, #""mem_total_mb":-1"#),
                       (#""disk_free_mb":17400"#, #""disk_free_mb":1e15"#), (#""load1":"0.42""#, #""load1":"0.42; id""#),
                       (#""load1":"0.42""#, #""load1":0.42"#), (#""slots":1"#, #""slots":5000"#), (#""slots":1"#, #""slots":"2""#), (#""cpus":2,"#, "")] {
        #expect(capacity(goodCapacity.replacingOccurrences(of: from, with: to)) == nil, "\(to)")
    }
}

@Test func capacityOpDropsBadJobRowsAndKeepsTheLast200() throws {
    let bad = [#"["2026-10-15T01:02:03Z",1,2,3]"#, #"["yesterday",1,2,3,0]"#, #"["2026-10-15T01:02:03Z",-1,2,3,0]"#, #"["2026-10-15T01:02:03Z",1,2,99999999,0]"#,
               #"["2026-10-15T01:02:03Z",1,2,3,999]"#, #"["2026-10-15T01:02:03Z","1",2,3,0]"#, #"{"at":1}"#, #""row""#]
    let report = try #require(capacity(goodCapacity.replacingOccurrences(of: #""jobs":["#, with: #""jobs":[\#(bad.joined(separator: ",")),"#)))
    #expect(report.jobs.count == 1 && report.jobs[0].peakMB == 480)
    let many = (0..<450).map { #"["2026-10-15T01:02:03Z",\#($0),1,1,0]"# }.joined(separator: ",")
    let capped = try #require(capacity(goodCapacity.replacingOccurrences(of: #"[["2026-10-15T01:02:03Z",12,300,480,0]]"#, with: "[\(many)]")))
    #expect(capped.jobs.count == 200 && capped.jobs.first?.waited == 250 && capped.jobs.last?.waited == 449)
}

// MARK: Capacity computation and advice

private let now = try! Date("2026-10-15T12:00:00Z", strategy: .iso8601)
private func job(daysAgo: Double, waited: Int, peak: Int) -> BoxCapacityReport.Job {
    .init(at: now.addingTimeInterval(-daysAgo * 86_400), waited: waited, ran: 60, peakMB: peak, exit: 0)
}

@Test func jobMemoryIsTheLargestRecentPeakOrTheDefault() {
    #expect(BoxCapacity.jobMB([]) == 600 && BoxCapacity.jobMB([job(daysAgo: 1, waited: 0, peak: 900), job(daysAgo: 1, waited: 0, peak: 900)]) == 600, "fewer than 3 jobs")
    #expect(BoxCapacity.jobMB([job(daysAgo: 1, waited: 0, peak: 200), job(daysAgo: 1, waited: 0, peak: 350), job(daysAgo: 1, waited: 0, peak: 300)]) == 350)
    let old = [job(daysAgo: 9, waited: 0, peak: 2000)] + (0..<20).map { _ in job(daysAgo: 1, waited: 0, peak: 250) }
    #expect(BoxCapacity.jobMB(old) == 250, "only the last 20 count")
    #expect(BoxCapacity.jobMB((0..<3).map { _ in job(daysAgo: 1, waited: 0, peak: 0) }) == 600, "nothing measured")
}

@Test func advisedFollowsTheFormula() {
    #expect(BoxCapacity.advised(cpus: 2, availMB: 1380, jobMB: 600) == 1)
    #expect(BoxCapacity.advised(cpus: 2, availMB: 400, jobMB: 600) == 1, "never below 1")
    #expect(BoxCapacity.advised(cpus: 4, availMB: 8000, jobMB: 600) == 4, "never above the CPUs")
    #expect(BoxCapacity.advised(cpus: 8, availMB: 2312, jobMB: 600) == 3)
    let capacity = BoxCapacity(BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380))
    #expect(capacity.jobMB == 600 && capacity.advised == 1 && capacity.slots == 1)
}

@Test func weekStatsCountOnlyTheLastSevenDays() {
    let report = BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, jobs: [job(daysAgo: 8, waited: 9000, peak: 300), job(daysAgo: 2, waited: 60, peak: 300),
                                                                                      job(daysAgo: 1, waited: 180, peak: 300), job(daysAgo: 0.1, waited: 0, peak: 300)])
    #expect(BoxCapacity(report).week(now: now) == .init(count: 3, averageWait: 80, longestWait: 180))
    #expect(BoxCapacity(BoxCapacityReport(cpus: 1, memTotalMB: 1, memAvailMB: 0)).week(now: now).count == 0)
}

@Test func adviceTable() {
    let waits = (0..<4).map { job(daysAgo: Double($0) + 0.5, waited: 840, peak: 400) }
    // Waited 14 min, 4 CPUs and room for 3 jobs of 400 MB while 1 slot is set: this box can run more.
    let roomy = BoxCapacity(BoxCapacityReport(cpus: 4, memTotalMB: 8000, memAvailMB: 1800, slots: 1, jobs: waits))
    #expect(roomy.advised == 3 && roomy.advice(now: now) == "Jobs waited 14 min on average this week. This box can run 3.")
    // Waited, but the box already runs what it can: a box twice the size (its RAM added, all free) would run 4.
    let full = BoxCapacity(BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, slots: 2, jobs: waits))
    #expect(full.advised == 2 && full.advice(now: now) == "Jobs waited 14 min on average this week; a box with 4 CPUs and 7.6 GB would run 4.")
    // Under a minute on average, or only old waits: no advice.
    let short = BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, jobs: (0..<4).map { _ in job(daysAgo: 1, waited: 59, peak: 400) })
    #expect(BoxCapacity(short).advice(now: now) == nil)
    let old = BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, jobs: (0..<4).map { job(daysAgo: 8 + Double($0), waited: 900, peak: 400) })
    #expect(BoxCapacity(old).advice(now: now) == nil)
    // Exactly 60 s average is advice-worthy and reads 1 min.
    let minute = BoxCapacityReport(cpus: 4, memTotalMB: 8000, memAvailMB: 4000, slots: 1, jobs: (0..<4).map { _ in job(daysAgo: 1, waited: 60, peak: 400) })
    #expect(BoxCapacity(minute).advice(now: now) == "Jobs waited 1 min on average this week. This box can run 4.")
}

@Test func capacityLineSaysWhoSetTheLimit() {
    let set = BoxCapacity(BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, slots: 1))
    #expect(set.line == "This box: 2 CPUs, 3.8 GB — 1 coding job at a time (set by you)" && set.notApplied == nil && !set.offersAdvised)
    let advised = BoxCapacity(BoxCapacityReport(cpus: 4, memTotalMB: 8192, memAvailMB: 3000))
    #expect(advised.line == "This box: 4 CPUs, 8 GB — 4 coding jobs at a time (advised)" && advised.offersAdvised && advised.notApplied != nil)
    let one = BoxCapacity(BoxCapacityReport(cpus: 1, memTotalMB: 2048, memAvailMB: 900))
    #expect(one.line == "This box: 1 CPU, 2 GB — 1 coding job at a time (advised)" && !one.offersAdvised && one.notApplied == nil && one.limitRange == 1...2)
    #expect(BoxCapacity.gigabytes(3891) == "3.8" && BoxCapacity.gigabytes(7782) == "7.6" && BoxCapacity.gigabytes(1024) == "1")
    #expect(BoxReadingsCopy.checked(try! Date("2026-10-15T09:12:00Z", strategy: .iso8601)).hasPrefix("Checked 15 Oct "))
}

// MARK: Sub-agents line

@Test func subAgentLineStates() {
    let reported = try! Date("2026-10-15T09:00:00Z", strategy: .iso8601)
    let pinned = SubAgentLine(models: BotModels(name: "jarvis", model: "gpt-5.6-terra", provider: "openai-codex", subModel: "gpt-6.1-sol", subProvider: "openai-codex"), reportedAt: reported, delegationOff: false)
    #expect(pinned.text == "Coding model: gpt-6.1-sol (reported 15 Oct)" && !pinned.offersCheck)
    let same = SubAgentLine(models: BotModels(name: "jarvis", model: "gpt-5.6-terra", provider: "openai-codex"), reportedAt: reported, delegationOff: false)
    #expect(same.text == "Coding model: same as this bot (gpt-5.6-terra)" && !same.offersCheck)
    let none = SubAgentLine(models: nil, reportedAt: nil, delegationOff: false)
    #expect(none.text == "Coding model: \(ModelRoleReason.boxOnly.text)" && none.offersCheck)
    let off = SubAgentLine(models: BotModels(name: "jarvis", model: "m", provider: "p", subModel: "gpt-6.1-sol"), reportedAt: reported, delegationOff: true)
    #expect(off.text == ModelRoleReason.subAgentsOff.text && !off.offersCheck, "sub-agents off wins")
}

/// Wording (Konrad, 15 Oct): the UI calls `delegation.model` the coding model. No string literal in Sources says
/// "sub-agent model" or "Sub-agents:" (comments are skipped); the help line and the sheet title read as the brief says.
@Test func theUICallsDelegationModelTheCodingModel() throws {
    #expect(BoxReadingsCopy.modelsHelp == "Used by sub-agents this bot starts, and for coding jobs when no coding agent (Claude Code, Codex) can run.")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sheet = try String(contentsOf: root.appending(path: "Sources/AgentApp/Views/SubAgentModelSheet.swift"), encoding: .utf8)
    #expect(sheet.contains(#"Text("Coding model").font(.title3"#))
    let files = try #require(FileManager.default.enumerator(at: root.appending(path: "Sources/AgentApp"), includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    for file in files {
        for (line, literal) in VisibleNameGuard.literals(in: try String(contentsOf: file, encoding: .utf8)) {
            #expect(!literal.localizedCaseInsensitiveContains("sub-agent model") && !literal.contains("Sub-agents:"), "\(file.lastPathComponent):\(line): \(literal)")
        }
    }
}

// MARK: Turns

@Test func readTurnsCarryOnlyTheirReadOnlyRecipe() throws {
    let models = try #require(BotManagerText.recipe(.models)), capacity = try #require(BotManagerText.recipe(.capacity))
    let readModels = try #require(BoxReadingsTurns.modelsInstructions(template: models))
    let readCapacity = try #require(BoxReadingsTurns.capacityInstructions(template: capacity))
    for text in [readModels, readCapacity] {
        #expect(text.contains("Reading needs no confirmation") && text.contains("````sh\n("))
        #expect(text.range(of: #"(^|[\s;&|(])hermes\s"#, options: .regularExpression) == nil && !text.contains("python") && !text.contains("config set"), "no Hermes start, no writes")
        #expect(!text.contains("SLOTS=$N") && !text.contains("<slots>"), "no limit write in a read turn")
    }
    #expect(readModels.contains(#"printf '{"op":"models","list":[%s]}\n'"#) && readModels.contains("tr -cd 'A-Za-z0-9._:/-'"))
    #expect(readCapacity.contains("/proc/meminfo") && readCapacity.contains("tail -n 200") && readCapacity.contains("df -Pm ~") && readCapacity.contains("nproc"))
}

@Test func limitTurnAsksFirstAndReportsTheCapacity() throws {
    let template = try #require(BotManagerText.recipe(.capacity))
    let text = try #require(BoxReadingsTurns.limitInstructions(3, template: template))
    #expect(text.contains("Ask him first") && text.contains("( N=3; D=~/.hermes/swarmhub;") && !text.contains("<slots>"))
    #expect(text.range(of: "SLOTS=$N")!.lowerBound < text.range(of: #""op":"box_capacity""#)!.lowerBound, "write, then probe")
    #expect(BoxReadingsTurns.limitInstructions(0, template: template) == nil && BoxReadingsTurns.limitInstructions(2000, template: template) == nil)
}

@Test func subAgentTurnFillsTheModelRecipeAndClearsWithEmptyValues() throws {
    let core = try #require(BotManagerText.template())
    let set = SubAgentModelChange(model: "gpt-6.1-sol", provider: "openai-codex", bots: .some(["jarvis", "mira"]))
    let text = try #require(BoxReadingsTurns.subAgentInstructions(set, core: core))
    #expect(text.contains("export MODEL=gpt-6.1-sol PROV=openai-codex KM=delegation.model KP=delegation.provider\n") && text.contains("printf '%s\\n' jarvis mira | xargs"))
    #expect(text.contains("Ask him first") && text.contains("cat ~/.hermes/swarmhub-model.log") && !text.contains("<names>") && !text.contains("KM=model.default"))
    let clear = try #require(BoxReadingsTurns.subAgentInstructions(.clear(.all), core: core))
    #expect(clear.contains("export MODEL= PROV= KM=delegation.model KP=delegation.provider\n") && clear.contains("printf '%s\\n' default $(ls ~/.hermes/profiles | grep -E"))
    #expect(clear.contains(#"tr -d "\"\047 "); [ "$C" = "$V" ] ||"#), "the skip check compares with quotes stripped: '', \"\" and missing are empty")
    #expect(SubAgentModelChange.clear(.all).request == "Clear the coding model of all bots: each bot's own model is used instead.")
    #expect(set.request == "Change the coding model of jarvis, mira to gpt-6.1-sol (openai-codex).")
    for bad in [SubAgentModelChange(model: "gpt; id", provider: "p", bots: .all), SubAgentModelChange(model: "m", provider: "", bots: .all),
                SubAgentModelChange(model: "m", provider: "p", bots: .some([])), SubAgentModelChange(model: "m", provider: "p", bots: .some(["../x"]))] {
        #expect(!bad.isValid && BoxReadingsTurns.subAgentInstructions(bad, core: core) == nil, "\(bad)")
    }
}

@Test func changeSubAgentModelIsOfferedOnlyToHermesManagers() {
    #expect(ManageBotsAction.actions(for: .hermes).contains(.changeSubAgentModel) && ManageBotsAction.changeSubAgentModel.title == "Change coding model…")
    #expect(!ManageBotsAction.actions(for: .openClaw).contains(.changeSubAgentModel))
    let hermes = ManageBotsAction.actions(for: .hermes)
    #expect(hermes.firstIndex(of: .changeSubAgentModel) == hermes.firstIndex(of: .changeModel)! + 1, "next to Change model…")
}

// MARK: Shell test

/// `Tests/Scripts/box-readings-test.sh`: both read recipes, the limit and the core skip check in a temp HOME.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func boxReadingsShellTestPasses(_ shell: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    let recipes = repoRoot.appending(path: "Resources/BotManager")
    process.arguments = [repoRoot.appending(path: "Tests/Scripts/box-readings-test.sh").path, recipes.appending(path: "recipes/models.md").path,
                         recipes.appending(path: "recipes/capacity.md").path, recipes.appending(path: "manager-hermes.md").path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "BOX_SH": shell]
    let (status, output) = try await runToEnd(process)
    if shellSuiteSkipped(status, output) { return }
    #expect(status == 0 && output.contains("box-readings tests under \(shell): 12 passed, 0 failed") && !output.contains("FAIL"), "\(output)")
}
