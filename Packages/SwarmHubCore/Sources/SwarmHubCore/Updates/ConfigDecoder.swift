import Foundation

/// The four app config documents (CORE-PLAN §1.2, SCHEMAS.md §12).
public enum ConfigDomain: String, CaseIterable, Sendable {
    case policy, prompts, copy, flags

    var document: String { rawValue + ".json" }
    var schema: String { "swarmhub/config-\(rawValue)/1" }
}

/// Why a component, document or key falls back to its compiled default. `component` is set for decode
/// reports, nil for reports made when a value is read; `domain`/`key` are nil when a whole component or
/// document is affected.
public struct ConfigReport: Hashable, Sendable, CustomStringConvertible {
    public let reason: String
    public let domain: String?
    public let key: String?
    public let component: String?

    public init(reason: String, domain: String? = nil, key: String? = nil, component: String? = nil) {
        self.reason = reason; self.domain = domain; self.key = key; self.component = component
    }

    public var description: String {
        "config fallback: \(reason) domain=\(domain ?? "-") key=\(key ?? "-") component=\(component ?? "-")"
    }
}

/// A stored config component in record (manifest) order; `archive` is nil when the stored copy no longer
/// matches the record.
struct ConfigComponent: Sendable {
    let name: String
    let archive: Data?
}

/// Everything the decoder accepted, plus why the rest was refused.
struct ConfigDocuments: Sendable {
    var values: [ConfigDomain: [String: JCS.Value]] = [:]
    /// `<domain>.<key>` of every key a kill flag sets to its compiled default.
    var killedKeys: Set<String> = []
    var killedViews: Set<String> = []
    var reports: [ConfigReport] = []
}

/// P6a decoder. Strict and total: anything it does not accept is reported and left to the compiled default,
/// and nothing here can fail the caller. The CORE-PLAN §4 denylist is enforced here, before any value is
/// readable, so no update-service document can name approval keys, approver lists, gates, or approval and
/// secret endpoints. `scripts/release/config_reference.py` is the Python statement of the same rules.
enum ConfigDecoder {
    static let maxDocumentBytes = 262_144
    static let keyPattern = "[A-Za-z0-9._-]{1,128}"
    /// Matched against the ASCII-lowercased name with `.`, `_` and `-` removed (and against policy strings).
    static let deniedFragments = [
        "allowlist", "apikey", "approv", "authent", "authoriz", "bearer", "blacklist", "blocklist", "confirm",
        "credential", "denylist", "endpoint", "enroll", "hmac", "keychain", "nonce", "operationreview",
        "passphrase", "password", "permission", "privatekey", "publickey", "secret", "signingkey", "webhook",
        "whitelist"
    ]
    /// Matched against the words of a name: split at `.`, `_`, `-` and before an uppercase letter that
    /// follows a lowercase letter or digit, then ASCII-lowercased.
    static let deniedWords: Set<String> = [
        "auth", "device", "devices", "gate", "gated", "gates", "gateway", "gating", "host", "hostname", "hosts",
        "key", "keys", "origin", "origins", "pin", "pinned", "pins", "signature", "signatures", "signer",
        "signing", "token", "tokens", "trust", "trusted", "uri", "url", "urls"
    ]
    static let killScopes: Set<String> = ["policy", "prompts", "copy", "flags", "view"]

    static func decode(_ components: [ConfigComponent]) -> ConfigDocuments {
        var result = ConfigDocuments()
        var found: [ConfigDomain: [(component: String, data: Data)]] = [:]
        for component in components {
            guard let archive = component.archive else {
                result.reports.append(ConfigReport(reason: "component_unreadable", component: component.name))
                continue
            }
            let files: [String: Data]
            do {
                let inspection = try ArchiveRules.check(archive, kind: "config")
                guard !inspection.needsCode else {
                    result.reports.append(ConfigReport(reason: "component_not_data", component: component.name))
                    continue
                }
                files = try ArchiveRules.files(archive, kind: "config")
            } catch let invalid as ArchiveRules.Invalid {
                result.reports.append(ConfigReport(reason: invalid.reason, component: component.name))
                continue
            } catch {
                result.reports.append(ConfigReport(reason: "archive_malformed", component: component.name))
                continue
            }
            // Only root-level documents count; other files (box prompt sources, notes) are not app config.
            for domain in ConfigDomain.allCases {
                if let data = files[domain.document] {
                    found[domain, default: []].append((component: component.name, data: data))
                }
            }
        }
        for domain in ConfigDomain.allCases {
            guard let documents = found[domain] else { continue }
            guard documents.count == 1 else {
                // Two sources for one document: neither wins, the whole domain stays compiled.
                for document in documents {
                    result.reports.append(ConfigReport(reason: "duplicate_document", domain: domain.rawValue,
                                                       component: document.component))
                }
                continue
            }
            decodeDocument(domain, component: documents[0].component, data: documents[0].data, into: &result)
        }
        return result
    }

    private static func decodeDocument(_ domain: ConfigDomain, component: String, data: Data,
                                       into result: inout ConfigDocuments) {
        func report(_ reason: String, _ key: String? = nil) {
            result.reports.append(ConfigReport(reason: reason, domain: domain.rawValue, key: key, component: component))
        }
        guard data.count <= maxDocumentBytes else { return report("config_too_large") }
        guard let parsed = try? JCS.parse(data) else { return report("config_invalid") }
        guard case .object(let members) = parsed, members["schema"] == .string(domain.schema) else {
            return report("schema_invalid")
        }
        var accepted: [String: JCS.Value] = [:]
        for key in sortedNames(members.keys) where key != "schema" && key != "note" {
            // A key from this dictionary always has a value.
            let value = members[key]!
            if let reason = nameProblem(key) ?? valueProblem(domain, value) {
                report(reason, key)
                continue
            }
            guard domain == .flags, key.hasPrefix("kill.") else {
                accepted[key] = value
                continue
            }
            let target = key.dropFirst("kill.".count)
            guard let dot = target.firstIndex(of: "."), killScopes.contains(String(target[..<dot])),
                  target.index(after: dot) != target.endIndex,
                  !target[target.index(after: dot)...].hasPrefix("kill.") else {
                report("invalid_kill", key)
                continue
            }
            // A kill flag only ever selects compiled behaviour; false is accepted and changes nothing.
            if value == .bool(true) {
                let scope = String(target[..<dot]), name = String(target[target.index(after: dot)...])
                if scope == "view" { result.killedViews.insert(name) } else { result.killedKeys.insert(scope + "." + name) }
            }
        }
        result.values[domain] = accepted
    }

    static func sortedNames<S: Sequence>(_ names: S) -> [String] where S.Element == String {
        names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// `invalid_key` or `denied_key` for a top-level or nested member name.
    static func nameProblem(_ name: String) -> String? {
        guard matches(name, keyPattern) else { return "invalid_key" }
        return deniedName(name) ? "denied_key" : nil
    }

    static func deniedName(_ name: String) -> Bool {
        let bytes = Array(name.utf8), flat = normalized(bytes)
        if deniedFragments.contains(where: { bytesContain(flat, Array($0.utf8)) }) { return true }
        var words: [[UInt8]] = [], word: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            if [45, 46, 95].contains(byte) {
                words.append(word); word = []
                continue
            }
            if (65...90).contains(byte), index > 0,
               (97...122).contains(bytes[index - 1]) || (48...57).contains(bytes[index - 1]) {
                words.append(word); word = []
            }
            word.append(lower(byte))
        }
        words.append(word)
        return words.contains { deniedWords.contains(String(decoding: $0, as: UTF8.self)) }
    }

    /// Domain value rules: flags are booleans, prompts and copy are strings, policy values carry no denied
    /// member names and no endpoint-like or denied strings at any depth.
    static func valueProblem(_ domain: ConfigDomain, _ value: JCS.Value) -> String? {
        switch (domain, value) {
        case (.flags, .bool), (.prompts, .string), (.copy, .string): return nil
        case (.flags, _), (.prompts, _), (.copy, _): return "wrong_type"
        case (.policy, _):
            var names: [String] = [], strings: [String] = []
            collect(value, names: &names, strings: &strings)
            if names.contains(where: { !matches($0, keyPattern) }) { return "invalid_key" }
            if names.contains(where: deniedName) { return "denied_key" }
            return strings.contains(where: deniedString) ? "denied_value" : nil
        }
    }

    static func deniedString(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        if bytes.first == 47 || bytesContain(bytes, Array("://".utf8)) { return true }
        let flat = normalized(bytes)
        return deniedFragments.contains { bytesContain(flat, Array($0.utf8)) }
    }

    private static func collect(_ value: JCS.Value, names: inout [String], strings: inout [String]) {
        switch value {
        case .string(let text): strings.append(text)
        case .array(let items): for item in items { collect(item, names: &names, strings: &strings) }
        case .object(let members):
            for (name, item) in members {
                names.append(name)
                collect(item, names: &names, strings: &strings)
            }
        case .integer, .bool: break
        }
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }

    private static func normalized(_ bytes: [UInt8]) -> [UInt8] {
        bytes.filter { ![45, 46, 95].contains($0) }.map(lower)
    }

    /// Byte search, so Unicode canonical equivalence can never hide an ASCII fragment.
    private static func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<start + needle.count].elementsEqual(needle)
        }
    }
}
