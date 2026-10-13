import Foundation
import Testing
@testable import AgentApp

let grokFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures").standardizedFileURL
let grokCacheFixture = grokFixtures.appending(path: "grok-cache")
let grokGoldenExport = grokFixtures.appending(path: "bundles/export")
private let jarvis = "00000000-0000-4000-8000-000000000001"
private let group = "00000000-0000-4000-8000-000000000004"

private func nativeBundles() throws -> [GrokBundleV1] {
    GrokBundleBuilder.build(try GrokCacheReader(folder: grokCacheFixture).read()).bundles
}
private func bundle(_ id: String) throws -> GrokBundleV1 { try #require(try nativeBundles().first { $0.sourceID == id }) }

/// The parsed value of what `JSONEncoder` writes, so the comparison covers the real encoding (nulls kept).
private func encoded(_ bundle: GrokBundleV1) throws -> JSONValue { try GrokJSON.parse(JSONEncoder().encode(bundle)) }

@Test func nativeBundlesEqualTheGoldenExportAsParsedValues() throws {
    let index = try GrokJSON.parse(Data(contentsOf: grokGoldenExport.appending(path: "index.json")))
    let entries = try #require(index["bots"]?.arrayValue)
    let native = try nativeBundles()
    #expect(native.map(\.sourceID) == entries.compactMap { $0["source_id"]?.stringValue })
    for entry in entries {
        let path = try #require(entry["bundle"]?.stringValue)
        let golden = try GrokJSON.parse(Data(contentsOf: grokGoldenExport.appending(path: path)))
        let mine = try #require(native.first { $0.sourceID == entry["source_id"]?.stringValue })
        #expect(try encoded(mine) == golden, "\(path)")
        #expect(mine.json.objectValue?.count == 21)
        #expect(GrokParity.differences(mine.json, golden).isEmpty)
        // The importer's view equals what the loader decodes from the golden file.
        #expect(GrokBotBundle(mine) == (try GrokBundleLoader.load(from: grokGoldenExport.appending(path: path))).first)
    }
}

@Test func parityCommandReportsEqualWithoutText() throws {
    var lines: [String] = []
    let arguments = ["AgentApp", "--grok-parity", grokGoldenExport.path, "--cache", grokCacheFixture.path]
    let code = GrokParity.run(arguments: arguments) { lines.append($0) }
    #expect(code == 0)
    #expect(lines.filter { $0.hasSuffix(": equal") }.count == 4 && lines.last == "bots=4 equal=4 different=0")
    #expect(!lines.joined().contains("synthetic") && !lines.joined().contains("Jarvis"))
    // A changed bundle is named by field and count only.
    var changed = try bundle(jarvis)
    changed.messages[0].text = "edited synthetic text"; changed.title = "x"
    let line = try #require(try GrokParity.compare(native: [changed], exportFolder: grokGoldenExport).first)
    #expect(line.rendered == "\(jarvis): differs messages (1), title (1)")
    #expect(try GrokParity.compare(native: [changed], exportFolder: grokGoldenExport).filter { $0.onlyIn != nil }.count == 3)
}

// The assertions of scripts/test_export_grokbot.py, on the native builder.

@Test func scriptAssertionsHoldNatively() throws {
    let native = try nativeBundles()
    let profiles = Dictionary(uniqueKeysWithValues: native.map { ($0.name, $0.profile) })
    #expect(profiles["Jarvis"] == "grok-jarvis" && profiles["Finance Controller"] == "grok-finance-controller")
    #expect(profiles["Konrad, Jarvis, Plain Bot"] == .some(nil))
    let j = try bundle(jarvis)
    #expect(j.messages.map(\.id) == ["j1", "j2", "j3", "j4", "j5", "j9", "j10", "j12"])
    #expect(j.messages.map(\.seq) == j.messages.map(\.seq).sorted())
    let roles = Dictionary(uniqueKeysWithValues: j.messages.map { ($0.id, [$0.role, $0.channel, $0.author ?? "-", $0.to ?? "-"]) })
    #expect(roles["j1"] == ["user", "chat", "-", "-"] && roles["j2"] == ["assistant", "chat", "Jarvis", "-"])
    #expect(roles["j3"] == ["assistant", "agent", "Jarvis", "Finance Controller"])
    #expect(roles["j4"] == ["assistant", "agent", "Finance Controller", "Jarvis"])
    #expect(roles["j9"]?.first == "system")
    #expect(j.statistics.cardsDropped == 1 && j.statistics.eventsDropped == 1 && j.statistics.toolEntriesDropped == 1)
    #expect(j.statistics.droppedByKind == ["send-message/secret-request": 1, "event/automation-changed": 1, "tool-call": 1])
    #expect(j.messages.filter(\.hidden).map(\.id) == ["j10"])
    #expect(j.events == [.init(id: "j7", seq: 7, timestampMs: .int(1_760_000_008_000), from: "Jarv", to: "Jarvis")])
    let text = String(decoding: try JSONEncoder().encode(j), as: UTF8.self)
    #expect(!text.contains("FAKETOKENVALUE1234") && !text.contains("FAKEFAKE1234") && !text.contains("example.invalid"))
    #expect(j.description.contains("[REDACTED]") && j.redactions.values.reduce(0, +) == 2)
    #expect(j.messages.first { $0.id == "j12" }?.attachments == [.init(file: "attachments/report_final.pdf", available: false)])
    let g = try bundle(group)
    #expect(g.isGroup && g.members.map(\.name) == ["Jarvis", "Plain Bot"] && g.members.map(\.profile) == ["grok-jarvis", "grok-plain-bot"])
    #expect(g.messages.map(\.author) == [nil, "Jarvis", "Plain Bot"])
    let plain = try #require(native.first { $0.name == "Plain Bot" })
    #expect(plain.avatarShape == nil && plain.avatarColour == nil)
}

// Deliberate differences from the script (briefs/P10.md P10a 4), each on its own synthetic entries.

private func mapped(_ entries: [String], names: [String: String] = ["agent-x": "Agent X"]) throws -> (GrokBundleV1, [String: Int]) {
    let parsed = try entries.map { try GrokJSON.parse(Data($0.utf8)) }
    let row: [String: JSONValue] = ["id": .string("bot-1"), "name": .string("Bot One")]
    var roster = [row]
    for (id, name) in names { roster.append(["id": .string(id), "name": .string(name)]) }
    let built = try #require(GrokBundleBuilder.build(roster: roster, transcripts: ["bot-1": parsed]).bundles.first)
    return (built, built.statistics.droppedByKind)
}

@Test func nullAgentFieldsCountAsAbsent() throws {
    let (b, _) = try mapped([
        #"{"kind":"message","id":"a","seq":1,"role":"user","content":"from me","fromAgent":null}"#,
        #"{"kind":"message","id":"b","seq":2,"role":"assistant","content":"plain reply","toAgent":null}"#,
        #"{"kind":"message","id":"c","seq":3,"role":"assistant","content":"to agent","toAgent":{}}"#,
        #"{"kind":"message","id":"d","seq":4,"role":"user","content":"from agent","fromAgent":{"id":"agent-x"}}"#,
    ])
    #expect(b.messages.map(\.id) == ["a", "c", "d"])
    #expect(b.messages[0].role == "user" && b.messages[0].author == nil)
    #expect(b.messages[1].to == "Agent" && b.messages[1].channel == "agent")      // presence is a key test: {} counts
    #expect(b.messages[2].author == "Agent X" && b.messages[2].to == "Bot One")
    #expect(b.statistics.toolEntriesDropped == 1)                               // assistant without toAgent is internal
}

@Test func typesAreCheckedNotCoerced() throws {
    let (b, dropped) = try mapped([
        #"{"kind":"notice","id":"a","seq":1.0,"text":"float seq"}"#,
        #"{"kind":"notice","id":"b","seq":true,"text":"bool seq"}"#,
        #"{"kind":"notice","id":7,"seq":3,"text":"number id"}"#,
        #"{"kind":"message","id":"c","seq":4,"role":"user","content":42}"#,
        #"{"kind":"notice","id":"d","seq":5,"text":["x"]}"#,
        #"{"kind":"notice","id":"e","seq":6,"text":"kept","timestampMs":true}"#,
        #""not an object""#,
    ])
    #expect(b.messages.map(\.id) == ["e"] && b.messages[0].timestamp == nil)
    #expect(dropped == ["invalid": 4, "message/empty": 1, "notice/empty": 1])
    #expect(b.statistics.toolEntriesDropped == 6)
}

@Test func dropsAreCountedPerKindAndCardType() throws {
    let (b, dropped) = try mapped([
        #"{"kind":"send-message","id":"a","seq":1,"message":{"type":"secret-request"}}"#,
        #"{"kind":"send-message","id":"b","seq":2,"message":{"type":"connector"}}"#,
        #"{"kind":"send-message","id":"c","seq":3,"message":{"type":"email-draft","draft":{"subject":"S","body":"B"}}}"#,
        #"{"kind":"event","id":"d","seq":4,"event":{"type":"automation-changed"}}"#,
        #"{"kind":"reasoning","id":"e","seq":5}"#,
        #"{"kind":"send-message","id":"f","seq":6,"message":{"type":"widget","widget":{"options":[{"value":"v"}]}},"#
            + #""author":{"id":"agent-x"}}"#,
    ])
    #expect(dropped == ["send-message/secret-request": 1, "send-message/connector": 1, "event/automation-changed": 1, "reasoning": 1])
    #expect(b.messages.map(\.text) == ["Email draft — S\n\nB", "• v"] && b.messages[1].author == "Agent X")
    #expect(b.limitations == [GrokBundleBuilder.cacheLimitation, GrokBundleBuilder.cardsLimitation, GrokBundleBuilder.eventsLimitation])
}

@Test func profilesAreValidUniqueAndNeverFromTheRosterID() throws {
    let rows: [[String: JSONValue]] = [
        ["id": .string("../evil"), "name": .string("R&D Bot")],
        ["id": .string("b"), "name": .string("r d bot")],
        ["id": .string("c"), "name": .string("")],
        ["id": .string("d"), "name": .string("R-D Bot")],
        ["id": .string("e"), "name": .null, "isGroup": .bool(true), "memberIds": .array([.string("../evil"), .string("d"), .int(5)])],
    ]
    let result = GrokBundleBuilder.build(roster: rows, transcripts: [:])
    #expect(result.bundles.map(\.profile) == ["grok-r-d-bot", nil, "grok-bot", nil, nil])
    #expect(result.bundles[1].name == "r d bot" && result.bundles[2].name == "Grok bot" && result.bundles[4].name == "Grok bot")
    #expect(result.warnings.map(\.sourceID) == ["b", "d"] && result.warnings.allSatisfy { $0.duplicateProfile == "grok-r-d-bot" })
    #expect(result.bundles[4].members.map(\.profile) == ["grok-r-d-bot", nil])
    #expect(result.bundles.allSatisfy { !($0.profile ?? "").contains("evil") && !$0.slug.contains("/") })
}
