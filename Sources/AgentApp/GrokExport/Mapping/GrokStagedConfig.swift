import CryptoKit
import Foundation

/// Routines and connector requests recovered from a Grok transcript (port of `staged_config` in
/// `scripts/export-grokbot.py`). Grok Bot keeps neither a schedule nor a prompt for an automation, only
/// `automation-changed` events (`automationId`, `automationName`, `action`), and a connector card names the connector.
/// Both import inert: routines paused and needing setup, connectors as requests the user opts into. A card's
/// `serverId` and `reauth.accountKey` are never read.
struct GrokStagedConfig {
    /// Positions are `(seq, index)`: the entries' order once sorted by seq, as the script sorts them.
    private struct Automation { var first: (Int64, Int); var latest: (Int64, Int); var action: String?; var named: (Int64, Int)?; var name: String? }
    private var automations: [String: Automation] = [:]
    private var connectors: [(order: (Int64, Int), raw: String)] = []

    static let routinePrefix = "grok-automation-"
    static let unnamedRoutine = "Imported routine"

    /// An `automation-changed` event with a non-blank string `automationId`; false leaves it to be counted as dropped.
    mutating func automation(_ event: [String: JSONValue], seq: Int64, index: Int) -> Bool {
        guard let id = event["automationId"]?.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let at = (seq, index)
        var automation = automations[id] ?? Automation(first: at, latest: at)
        if at < automation.first { automation.first = at }
        if at >= automation.latest { automation.latest = at; automation.action = event["action"]?.stringValue }
        if let name = event["automationName"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           automation.named.map({ at >= $0 }) ?? true {
            automation.named = at; automation.name = name
        }
        automations[id] = automation
        return true
    }

    /// A connector card with a string `connector`; false leaves it to be counted as dropped.
    mutating func connector(_ card: [String: JSONValue], seq: Int64, index: Int) -> Bool {
        guard let raw = card["connector"]?.stringValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        connectors.append(((seq, index), raw))
        return true
    }

    /// The latest state of each automation wins; a deleted one is left out. Names are redacted, ids are hashed.
    func routines(redact: inout GrokRedactor) -> [GrokBundleV1.Routine] {
        automations.filter { $0.value.action != "deleted" }
            .sorted { $0.value.first < $1.value.first }
            .map { id, automation in
                let name = redact(automation.name ?? Self.unnamedRoutine).trimmingCharacters(in: .whitespacesAndNewlines)
                return GrokBundleV1.Routine(id: Self.routineID(id), name: name.isEmpty ? Self.unnamedRoutine : name)
            }
    }

    /// Each distinct connector once, in first-seen order; one whose name held a secret is left out.
    func connectorNames(redact: inout GrokRedactor) -> [String] {
        var seenRaw: Set<String> = [], names: [String] = []
        for (_, raw) in connectors.sorted(by: { $0.order < $1.order }) where seenRaw.insert(raw).inserted {
            let clean = redact(raw)
            guard clean == raw else { continue }
            let name = Self.connectorName(raw)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// `grok-automation-` + the first 24 hex digits of SHA-256(automationId): stable, and never the raw id.
    static func routineID(_ automationID: String) -> String {
        routinePrefix + SHA256.hash(data: Data(automationID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    }

    /// A routine id as the importer keeps it (`grokRoutineIDs` lands in store.json): an exported `grok-automation-` id
    /// as is; anything else, as a hand-made or older bundle file may carry, hashed like a raw `automationId`, so a
    /// credential-shaped id never survives into the store.
    static func safeRoutineID(_ id: String) -> String {
        let hex = id.dropFirst(routinePrefix.count)
        let exported = id.hasPrefix(routinePrefix) && hex.count == 24 && hex.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
        return exported ? id : routineID(id)
    }

    /// ASCII letters lowercased, digits kept, every other run of characters one `-`, trimmed, at most 64 characters.
    static func connectorName(_ raw: String) -> String {
        var name = "", dash = false
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) {
                name.unicodeScalars.append(Unicode.Scalar((0x41...0x5A).contains(value) ? value + 32 : value)!); dash = false
            } else if !dash { name += "-"; dash = true }
        }
        return String(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
