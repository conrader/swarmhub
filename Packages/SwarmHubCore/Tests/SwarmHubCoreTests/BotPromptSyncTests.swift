import Foundation
import Testing
@testable import SwarmHubCore

// The same vectors run through the Python port in sim/test_prompt_sync.py.
private let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/prompt_sync_vectors.json")

private func vectors() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: vectorsURL))
    return try #require(object as? [String: Any])
}

private func decode<T: Decodable>(_ type: T.Type, _ object: Any?) throws -> T {
    let present = try #require(object)
    return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: present, options: [.fragmentsAllowed]))
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

private func resolve(_ reference: Any?, in root: [String: Any]) throws -> BotPromptContext {
    let reference = try #require(reference as? [String: Any])
    let contexts = try #require(root["contexts"] as? [String: Any])
    var context = try decode(BotPromptContext.self, contexts[try #require(reference["base"] as? String)])
    if let overrides = reference["with"] { try decode(PartialContext.self, overrides).apply(to: &context) }
    return context
}

private func stamp(_ settings: BotPromptSettings?, _ field: String) -> (at: Int64, origin: String, value: Any)? {
    if field == "approvalRules" { return settings?.approvalRules.map { ($0.at, $0.origin, $0.value) } }
    let paths: [String: KeyPath<BotPromptSettings, PromptStamp<String>?>] = [
        "name": \.name, "role": \.role, "owner": \.owner, "coordinator": \.coordinator,
        "timeZone": \.timeZone, "language": \.language, "quietHours": \.quietHours,
    ]
    guard let path = paths[field] else { return nil }
    return settings?[keyPath: path].map { ($0.at, $0.origin, $0.value) }
}

private func run(_ scenario: [String: Any], root: [String: Any]) throws {
    let name = scenario["name"] as? String ?? "?"
    var devices: [String: BotPromptSyncState] = [:]
    for case let op as [String: Any] in try #require(scenario["ops"] as? [Any]) {
        let device = op["device"] as? String ?? ""
        let bot = op["bot"] as? String ?? ""
        let now = (op["now"] as? NSNumber)?.int64Value ?? 0
        switch op["op"] as? String {
        case "observe":
            devices[device, default: .init()].observe(try resolve(op["context"], in: root), key: bot, origin: device, now: now)
        case "edit":
            let changes = try decode(PartialContext.self, op["set"])
            devices[device, default: .init()].edit(key: bot, origin: device, now: now,
                                                   fallback: try resolve(op["fallback"], in: root)) { changes.apply(to: &$0) }
        case "sync":
            // Through the wire format, as a transport would carry it.
            let from = try #require(op["from"] as? String), to = try #require(op["to"] as? String)
            let wire = try JSONEncoder().encode(devices[from, default: .init()].document)
            let carried = try JSONDecoder().decode(BotPromptDocument.self, from: wire)
            devices[to, default: .init()].merge(carried)
        case "receive":
            let document = try decode(BotPromptDocument.self, op["document"])
            let merged = devices[device, default: .init()].merge(document)
            #expect(merged == (op["merged"] as? Bool), "\(name)")
        case "expect":
            let expected = try resolve(op["context"], in: root)
            let got = devices[device, default: .init()].context(for: bot, fallback: try resolve(op["fallback"], in: root))
            #expect(got == expected, "\(name)")
        case "stamp":
            let field = try #require(op["field"] as? String)
            let got = stamp(devices[device]?.document.bots[bot], field)
            if op["at"] is NSNull {
                #expect(got == nil, "\(name)")
            } else {
                #expect(got?.at == (op["at"] as? NSNumber)?.int64Value && got?.origin == op["origin"] as? String, "\(name)")
                if let value = op["value"] as? String { #expect(got?.value as? String == value, "\(name)") }
            }
        default:
            Issue.record("unknown op in \(name)")
        }
    }
}

@Test func sharedPromptSyncVectorsMatchThePythonSimulation() throws {
    let root = try vectors()
    let scenarios = try #require(root["scenarios"] as? [[String: Any]])
    #expect(scenarios.count >= 10)
    for scenario in scenarios { try run(scenario, root: root) }
}

@Test func macAndPhoneDeriveTheSameBotKey() throws {
    let items = try #require(try vectors()["botKeys"] as? [[String: String]])
    #expect(!items.isEmpty)
    for item in items {
        let text = try #require(item["address"]), profile = try #require(item["profile"])
        #expect(BotPromptDocument.botKey(try ConnectionAddress(text, profile: profile)) == item["key"])
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
