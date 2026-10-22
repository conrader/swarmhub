import Foundation
import Testing
@testable import AgentApp

// P21b: the simple right panel. Model line and picker on top, roles and supplier detail under Advanced; the routine
// schedule picker and its raw text round-trip; group routing detail folded; Import Template only in the + menu; plain words.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func source(_ path: String) throws -> String { try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8) }

/// The right panel's simple views: no string literal reaches a control (`SimpleSettingsTests` scans them).
let inspectorSimpleFiles = ["Sources/AgentApp/Views/ModelSectionView.swift", "Sources/AgentApp/Views/RoutineEditorSheet.swift",
                            "Sources/AgentApp/Views/GroupMembersView.swift", "Sources/AgentApp/Views/AdvancedFold.swift",
                            "Sources/AgentApp/Views/WebhooksSection.swift", "Sources/AgentApp/Views/WebhookSheet.swift"]
/// Right-panel files that still hold their own words (tabs and the Advanced parts): none of them says "bot".
private let inspectorWordFiles = ["Sources/AgentApp/Views/InfoPanel.swift", "Sources/AgentApp/Views/RoutinesView.swift",
                                  "Sources/AgentApp/Views/BotCapabilitiesView.swift", "Sources/AgentApp/Views/ModelSectionAdvanced.swift",
                                  "Sources/AgentApp/Views/RoutineScheduleAdvanced.swift", "Sources/AgentApp/Views/GroupRoutingDetails.swift"]

// MARK: 1. Model

@MainActor private func picker(_ info: BotServerInfo?, current: CurrentModel? = nil, session: String? = nil) -> ModelPickerModel {
    ModelPickerModel(info: info, current: current, sessionID: session, profile: "default")
}

@MainActor @Test func theModelLineNamesModelAndSupplierInPlainWords() {
    var info = HeadlessInspector.sampleInfo()
    let current = CurrentModel(model: "sample-large", provider: "sample-cloud", source: CurrentModel.agentDefault)
    var line = ModelSimpleLine(picker: picker(info, current: current, session: "s1"), isRefreshing: false, error: nil)
    #expect(line.line == "Model: sample-large · Sample Cloud" && line.showsPicker && line.pickerTitle == InspectorCopy.changeModel)
    #expect(line.status == nil && !line.isWarning, "a chat that can switch needs no extra sentence")
    let model = picker(info, current: current, session: "s1")
    #expect(model.groups.map(\.name) == ["Sample Cloud", "Sample Local"] && model.groups.flatMap(\.items).allSatisfy(\.isEnabled),
            "the plain picker lists this agent's own models, grouped as before")

    line = ModelSimpleLine(picker: picker(info, current: current), isRefreshing: false, error: nil)
    #expect(line.status == InspectorCopy.modelSendFirst && line.showsPicker)
    info.capabilities = HermesCapabilities(features: ["session_model_lock": false])
    #expect(ModelSimpleLine(picker: picker(info, current: current, session: "s1"), isRefreshing: false, error: nil).status == InspectorCopy.modelFixed)
    info.refreshError = "The box did not answer."
    let warned = ModelSimpleLine(picker: picker(info, current: current, session: "s1"), isRefreshing: false, error: nil)
    #expect(warned.status == InspectorCopy.modelAttention && warned.isWarning)
    #expect(ModelSimpleLine(picker: picker(HeadlessInspector.sampleInfo(), current: current, session: "s1"), isRefreshing: false, error: "Rejected").isWarning)

    let loading = ModelSimpleLine(picker: picker(nil), isRefreshing: true, error: nil)
    #expect(loading.line == InspectorCopy.modelChecking && loading.status == InspectorCopy.modelsLoading && !loading.showsPicker)
    let blocked = ModelSimpleLine(picker: ModelPickerModel(reason: ModelCatalog.noKey, profile: "default"), isRefreshing: false, error: nil)
    #expect(blocked.line == InspectorCopy.modelNotReported && blocked.status == InspectorCopy.modelsNotListed && !blocked.showsPicker)
    let unlisted = ModelSimpleLine(picker: picker(HeadlessInspector.sampleInfo(), current: .init(model: "other", provider: nil, source: "this chat"), session: "s1"),
                                   isRefreshing: false, error: nil)
    #expect(unlisted.line == "Model: other · \(ModelPickerModel.notListed)")
    var busy = HeadlessInspector.sampleInfo(); busy.isSwitchingModel = true
    let switching = ModelSimpleLine(picker: picker(busy, current: current, session: "s1"), isRefreshing: false, error: nil)
    #expect(switching.pickerTitle == InspectorCopy.switching && switching.status == nil)
}

@Test func rolesAndSupplierDetailLiveUnderAdvancedAndPicksApplyAsBefore() throws {
    #expect(InspectorLayout.ids(.model, .simple) == ["model.current", "model.picker", "model.refresh", "model.status"])
    for id in ["model.roles", "model.ranOn", "model.source", "model.caption", "model.footer", "model.notes"] { #expect(InspectorLayout.home(of: id) == .advanced) }
    let simple = try source("Sources/AgentApp/Views/ModelSectionView.swift"), advanced = try source("Sources/AgentApp/Views/ModelSectionAdvanced.swift")
    #expect(!simple.contains("ModelRolesReadout(") && advanced.contains("ModelRolesReadout(bot: bot, cache: cache)"))
    #expect(!simple.contains("picker.caption") && !simple.contains("picker.footer") && advanced.contains("picker.caption") && advanced.contains("picker.footer"))
    #expect(simple.contains("AdvancedFold { ModelSectionAdvanced("))
    #expect(simple.contains("await store.switchModel(for: bot, provider: item.supplierSlug, model: item.model)"), "a pick goes through the same call")
}

// MARK: Layout table

@Test func everyRightPanelControlHasExactlyOneHome() {
    let ids = InspectorLayout.entries.map(\.id)
    #expect(Set(ids).count == ids.count, "no control is listed twice")
    #expect(Set(ids) == Set(InspectorLayout.baseline + InspectorLayout.added), "none lost, none invented")
    for section in InspectorLayout.Section.allCases {
        #expect(!InspectorLayout.ids(section, .simple).isEmpty && !InspectorLayout.ids(section, .advanced).isEmpty, "\(section) has both parts")
    }
}

// MARK: 2. Routine schedule

@Test func everyPickerScheduleWritesTextThatReadsBackToTheSamePicker() {
    var drafts: [RoutineScheduleDraft] = []
    for (hour, minute) in [(0, 0), (9, 0), (8, 30), (23, 59), (12, 5)] {
        for preset in [RoutinePreset.daily, .weekdays] { var d = RoutineScheduleDraft(); d.preset = preset; d.hour = hour; d.minute = minute; drafts.append(d) }
        for day in 0..<7 { var d = RoutineScheduleDraft(); d.preset = .weekly; d.hour = hour; d.minute = minute; d.weekday = day; drafts.append(d) }
    }
    for step in RoutineScheduleDraft.hourSteps { var d = RoutineScheduleDraft(); d.preset = .everyHours; d.everyHours = step; drafts.append(d) }
    for draft in drafts {
        let read = RoutineScheduleDraft(editing: draft.expression)
        #expect(read.preset == draft.preset && read.expression == draft.expression, "\(draft.expression)")
        #expect(!RoutineScheduleEditor(schedule: draft.expression).opensAdvanced)
    }
    var hours = RoutineScheduleDraft(); hours.preset = .everyHours; hours.everyHours = 6
    #expect(hours.expression == "0 */6 * * *" && RoutineScheduleDraft.describe("0 */6 * * *") == "Every 6 hours")
    hours.everyHours = 1; #expect(hours.expression == "0 * * * *" && RoutineScheduleDraft.describe(hours.expression) == "Every hour")
    #expect(RoutinePreset.pickable == [.daily, .weekdays, .weekly, .everyHours])
}

@Test func anythingThePickerCannotShowOpensUnderAdvancedExactlyAsStored() {
    let raw = ["0 9 * * 7", "00 09 * * *", "*/15 9-17 * * 1-5", "0 */5 * * *", "30 */2 * * *", "0 9 1 * *", "0 9 * * 1,3", "0 9 * 1 *",
               "every 30m", "every 2h", "2026-10-20T09:00:00", "30m", "0 9 * * * *", "0 9 * *", "60 9 * * *", "0 24 * * *", "0 9 * * 8", "When CI completes"]
    for text in raw {
        let editor = RoutineScheduleEditor(schedule: text)
        #expect(editor.draft.preset == .custom && editor.opensAdvanced, "\(text) opens in Advanced")
        #expect(editor.raw == text && editor.expression == text, "\(text) is kept as written")
    }
    let padded = RoutineScheduleEditor(schedule: " 0 9 * * * ")
    #expect(padded.draft.preset == .daily && padded.expression == "0 9 * * *" && padded.raw == " 0 9 * * * ", "saved trimmed, as before")
    #expect(RoutineScheduleDraft(parsing: "0 9 * * 7").weekday == 0 && RoutineScheduleDraft.describe("0 9 * * 7") == "Sundays at 09:00", "rows describe as before")
    let fresh = RoutineScheduleEditor(schedule: nil)
    #expect(fresh.expression == "0 9 * * *" && !fresh.opensAdvanced)
}

@Test func rawTextAndPickerFollowEachOther() {
    var editor = RoutineScheduleEditor(schedule: "0 9 * * 7")
    editor.setRaw("0 9 * * 1"); #expect(editor.draft.preset == .weekly && editor.draft.weekday == 1 && editor.raw == "0 9 * * 1")
    editor.pick { $0.hour = 10 }; #expect(editor.raw == "0 10 * * 1" && editor.expression == "0 10 * * 1")
    editor.setRaw("0 10 * * 1 "); #expect(editor.raw == "0 10 * * 1 ", "typing is never rewritten under the cursor")
    editor.setRaw("every 45m"); #expect(editor.draft.preset == .custom && editor.expression == "every 45m")
    editor.pick { $0.preset = .everyHours; $0.everyHours = 4 }; #expect(editor.raw == "0 */4 * * *" && editor.expression == "0 */4 * * *")
    editor.setRaw("bad"); editor.pick { $0.preset = .custom }; #expect(editor.raw == "bad", "choosing Custom keeps the text")
}

@Test func pickerTimesAreTheNumbersWrittenInEveryTimeZone() throws {
    for zone in ["UTC", "Europe/Warsaw", "America/St_Johns", "Asia/Kathmandu", "Pacific/Chatham", "America/Los_Angeles"] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: zone))
        for (hour, minute) in [(0, 0), (2, 30), (9, 15), (23, 59)] {
            let time = RoutineScheduleDraft.pickerTime(RoutineScheduleDraft.pickerDate(hour: hour, minute: minute, calendar: calendar), calendar: calendar)
            #expect(time.hour == hour && time.minute == minute, "\(zone) \(hour):\(minute)")
        }
    }
    var draft = RoutineScheduleDraft(); draft.hour = 23; draft.minute = 45
    #expect(draft.expression == "45 23 * * *", "no conversion: the box applies its own time zone, as before")
    #expect(InspectorCopy.scheduleSummary("Daily at 23:45").contains("your box's time zone"))
}

// MARK: 3. Groups

@MainActor @Test func theGroupPanelShowsMembersOnTopAndRoutingUnderAdvanced() throws {
    #expect(InspectorLayout.ids(.group, .simple) == ["group.name", "group.count", "group.owner", "group.members", "group.remove", "group.add", "group.mute"])
    #expect(InspectorLayout.ids(.group, .advanced) == ["group.memberWhere", "group.routing", "group.mentions", "group.contextCap"])
    let panel = try source("Sources/AgentApp/Views/GroupMembersView.swift"), detail = try source("Sources/AgentApp/Views/GroupRoutingDetails.swift")
    for call in ["store.removeMember(bot.id, from: group)", "store.addMember(bot, to: group)", "store.renameGroup(group, to: name)", "group.isMuted = $0; store.save()"] {
        #expect(panel.contains(call), "\(call) is unchanged")
    }
    #expect(!panel.contains("hermesProfile") && !panel.contains("Without an @mention") && detail.contains("GroupRouting.contextLimit") && detail.contains("@mention"))
    #expect(panel.contains("AdvancedFold { GroupRoutingDetails("))
    let ada = Bot(name: "Ada", backend: .hermes, hermesProfile: "grok-ada")
    #expect(GroupRoutingDetails.place(ada) == "Hermes · grok-ada" && GroupRoutingDetails.place(Bot(name: "M")) == BackendKind.mock.rawValue)

    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let b = Bot(name: "B", backend: .hermes, hermesProfile: "b"); store.bots = [ada, b]
    let group = try #require(store.createGroup(name: "G", memberIDs: [ada.id, b.id]))
    #expect(!group.isMuted && GroupRouting.recipients(of: "hi", members: [.init(id: ada.id, name: "Ada"), .init(id: b.id, name: "B")]) == [ada.id, b.id])
}

// MARK: 4. Import Template

@Test func importTemplateLivesInThePlusMenuNotInTheRightPanel() throws {
    for file in inspectorSimpleFiles + inspectorWordFiles {
        let text = try source(file)
        #expect(!text.contains("showingTemplateImport") && !text.localizedCaseInsensitiveContains("Import Template"), "\(file) offers no template import")
    }
    let sidebar = try source("Sources/AgentApp/Views/SidebarView.swift")
    #expect(sidebar.contains("Button(\"Import Template…\", systemImage: \"square.and.arrow.down\") { store.showingTemplateImport = true }"))
    #expect(AppCommand.allCases.contains(.importTemplate), "the menu bar command stays")
}

// MARK: 5. Words

@Test func theRightPanelSaysAgentNotBot() throws {
    let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    let interpolation = try NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
    for file in inspectorSimpleFiles + inspectorWordFiles {
        // Interpolations (code, which may hold quotes) go first; what is left between quotes is shown text.
        let source = try source(file)
        let text = interpolation.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
        for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let words = String(text[Range(match.range, in: text)!])
            #expect(words.range(of: #"\bbots?\b"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(file): \(words)")
        }
    }
}
