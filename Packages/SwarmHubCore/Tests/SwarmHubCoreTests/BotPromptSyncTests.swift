import Foundation
import Testing
@testable import SwarmHubCore

// The same vectors run through the Python port in sim/test_prompt_sync.py.
private let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/prompt_sync/index.json")

// Decode directly from source bytes. JSONSerialization/NSNumber can round Int64.max through Double.
private struct FixtureManifest: Decodable {
    var contexts: [String: BotPromptContext]
    var botKeys: [BotKeyVector]
    var scenarioFiles: [String]
}

private struct BotKeyVector: Decodable {
    var address, profile, key: String
}

private struct Scenario: Decodable {
    var name: String
    var ops: [Operation]
}

private struct ContextReference: Decodable {
    var base: String
    var with: PartialContext?
}

private enum StampValue: Decodable, Equatable {
    case text(String), rules([String])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .rules(try value.decode([String].self)) }
    }
}

private struct Operation: Decodable {
    var op: String
    var device, bot, from, to, field, origin: String?
    var now, at: Int64?
    var context, fallback: ContextReference?
    var set: PartialContext?
    var document: BotPromptDocument?
    var merged: Bool?
    var value: StampValue?
}

private func vectors() throws -> (root: FixtureManifest, scenarios: [Scenario]) {
    let decoder = JSONDecoder()
    let root = try decoder.decode(FixtureManifest.self, from: Data(contentsOf: vectorsURL))
    let scenarios = try root.scenarioFiles.flatMap { name in
        try decoder.decode([Scenario].self, from: Data(contentsOf: vectorsURL.deletingLastPathComponent().appendingPathComponent(name)))
    }
    return (root, scenarios)
}

/// A vector's `with`/`set` overrides; coordinator "" means no coordinator, as in the synced document.
private struct PartialContext: Decodable {
    var name, role, owner, coordinator, timeZone, language, quietHours: String?
    var approvalRules: [String]?

    func apply(to context: inout BotPromptContext) {
        if let name { context.name = name }
        if let role { context.role = role }
        if let owner { context.owner = owner }
        if let coordinator { context.coordinator = coordinator.isEmpty ? nil : coordinator }
        if let timeZone { context.timeZone = timeZone }
        if let language { context.language = language }
        if let quietHours { context.quietHours = quietHours }
        if let approvalRules { context.approvalRules = approvalRules }
    }
}

private func resolve(_ reference: ContextReference?, in root: FixtureManifest) throws -> BotPromptContext {
    let reference = try #require(reference)
    var context = try #require(root.contexts[reference.base])
    reference.with?.apply(to: &context)
    return context
}

private func stamp(_ settings: BotPromptSettings?, _ field: String) -> (at: Int64, origin: String, value: StampValue)? {
    if field == "approvalRules" { return settings?.approvalRules.map { ($0.at, $0.origin, .rules($0.value)) } }
    let paths: [String: KeyPath<BotPromptSettings, PromptStamp<String>?>] = [
        "name": \.name, "role": \.role, "owner": \.owner, "coordinator": \.coordinator,
        "timeZone": \.timeZone, "language": \.language, "quietHours": \.quietHours,
    ]
    guard let path = paths[field] else { return nil }
    return settings?[keyPath: path].map { ($0.at, $0.origin, .text($0.value)) }
}

private func run(_ scenario: Scenario, root: FixtureManifest) throws {
    let name = scenario.name
    var devices: [String: BotPromptSyncState] = [:]
    for op in scenario.ops {
        let device = op.device ?? ""
        let bot = op.bot ?? ""
        switch op.op {
        case "observe":
            devices[device, default: .init()].observe(try resolve(op.context, in: root), key: bot, origin: device, now: try #require(op.now))
        case "edit":
            let changes = try #require(op.set)
            devices[device, default: .init()].edit(key: bot, origin: device, now: try #require(op.now),
                                                   fallback: try resolve(op.fallback, in: root)) { changes.apply(to: &$0) }
        case "sync":
            // Through the wire format, as a transport would carry it.
            let from = try #require(op.from), to = try #require(op.to)
            let wire = try JSONEncoder().encode(devices[from, default: .init()].document)
            let carried = try JSONDecoder().decode(BotPromptDocument.self, from: wire)
            devices[to, default: .init()].merge(carried)
        case "receive":
            let document = try #require(op.document)
            let merged = devices[device, default: .init()].merge(document)
            #expect(merged == op.merged, "\(name)")
        case "expect":
            let expected = try resolve(op.context, in: root)
            let got = devices[device, default: .init()].context(for: bot, fallback: try resolve(op.fallback, in: root))
            #expect(got == expected, "\(name)")
        case "stamp":
            let field = try #require(op.field)
            let got = stamp(devices[device]?.document.bots[bot], field)
            if let at = op.at {
                #expect(got?.at == at && got?.origin == op.origin, "\(name)")
                if let value = op.value { #expect(got?.value == value, "\(name)") }
            } else {
                #expect(got == nil, "\(name)")
            }
        default:
            Issue.record("unknown op in \(name)")
        }
    }
}

@Test func sharedPromptSyncVectorsMatchThePythonSimulation() throws {
    let (root, scenarios) = try vectors()
    #expect(scenarios.count == 19)
    for scenario in scenarios { try run(scenario, root: root) }
}

@Test func sharedPromptSyncCeilingFixturesDecodeAsExactIntegers() throws {
    let scenarios = try vectors().scenarios
    let owner = try #require(scenarios.first { $0.name.hasPrefix("owner: edits saturate") })
    #expect(owner.ops.first?.document?.bots["k"]?.owner?.at == Int64.max - 1)
    #expect(owner.ops.first { $0.op == "stamp" }?.at == Int64.max)
    #expect(owner.ops.first { $0.now == Int64.max } != nil)
    let rules = try #require(scenarios.first { $0.name.hasPrefix("approvalRules: edits saturate") })
    #expect(rules.ops.first?.document?.bots["k"]?.approvalRules?.at == Int64.max - 1)
    #expect(rules.ops.first { $0.op == "stamp" }?.at == Int64.max)
    let received = try #require(scenarios.first { $0.name.hasPrefix("received Int64.max") })
    #expect(received.ops.first?.document?.bots["k"]?.owner?.at == Int64.max)
}

@Test func macAndPhoneDeriveTheSameBotKey() throws {
    let items = try vectors().root.botKeys
    #expect(!items.isEmpty)
    for item in items {
        #expect(BotPromptDocument.botKey(try ConnectionAddress(item.address, profile: item.profile)) == item.key)
    }
}

@Test func syncedSlotsRenderWhileTheCustomPersonaStaysExact() throws {
    var mac = BotPromptSyncState(), phone = BotPromptSyncState()
    let local = BotPromptContext(name: "Scout", role: "Research", owner: "Konrad", coordinator: "Jarvis (grok-jarvis)",
                                 timeZone: "Europe/Warsaw", language: "Polski", approvalRules: ["Deny deletes"], quietHours: "23:00–07:00")
    mac.observe(local, key: "k", origin: "mac", now: 1_000)
    phone.merge(mac.document)
    let context = phone.context(for: "k", fallback: BotPromptContext(name: "Scout", timeZone: "UTC"))
    #expect(context == local)
    let persona = "Speak warmly.\nReply with exactly approve, deny, or escalate."
    let prompt = BotSystemPrompt.compose(policy: try BotSystemPrompt.render(context), instructions: persona)
    #expect(prompt.hasSuffix(persona) && prompt.contains("\"owner\":\"Konrad\"") && prompt.contains("\"language\":\"Polski\""))
    let wire = String(decoding: try JSONEncoder().encode(mac.document), as: UTF8.self)
    #expect(!wire.contains("persona") && !wire.contains(persona))
}

@Test func wireShapeMatchesTheSimulationAndRoundTrips() throws {
    var state = BotPromptSyncState()
    state.edit(key: "k", origin: "ios", now: 42, fallback: BotPromptContext(name: "Scout")) { $0.owner = "K."; $0.coordinator = "Ops" }
    let data = try JSONEncoder().encode(state.document)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schema"] as? Int == 1)
    let bot = try #require((object["bots"] as? [String: Any])?["k"] as? [String: Any])
    #expect(Set(bot.keys) == ["owner", "coordinator"], "only edited fields are published; defaults stay local")
    let owner = try #require(bot["owner"] as? [String: Any])
    #expect(owner["value"] as? String == "K." && owner["at"] as? Int == 42 && owner["origin"] as? String == "ios")
    #expect(try JSONDecoder().decode(BotPromptDocument.self, from: data) == state.document)
    let state2 = try JSONDecoder().decode(BotPromptSyncState.self, from: JSONEncoder().encode(state))
    #expect(state2 == state)
}
