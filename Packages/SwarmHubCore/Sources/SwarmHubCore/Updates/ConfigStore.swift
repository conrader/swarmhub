import Foundation
#if canImport(os)
import os
#endif

/// A typed config key with its compiled default. The default is what the app does today; a bundle can only
/// replace it with a value of the same type that passed the decoder (SCHEMAS.md §12).
public struct ConfigKey<Value: Sendable>: Sendable {
    public let domain: ConfigDomain
    public let name: String
    public let fallback: Value
    /// Throws `ConfigReadFailure` for a present value this key cannot use.
    let decode: @Sendable (JCS.Value) throws -> Value

    init(_ domain: ConfigDomain, _ name: String, _ fallback: Value, decode: @escaping @Sendable (JCS.Value) throws -> Value) {
        self.domain = domain; self.name = name; self.fallback = fallback; self.decode = decode
    }
}

struct ConfigReadFailure: Error { let reason: String }

private func configString(_ value: JCS.Value) throws -> String {
    guard case .string(let text) = value else { throw ConfigReadFailure(reason: "wrong_type") }
    return text
}

private func configInteger(_ value: JCS.Value, _ range: ClosedRange<Int64>?) throws -> Int64 {
    guard case .integer(let number) = value else { throw ConfigReadFailure(reason: "wrong_type") }
    guard range?.contains(number) ?? true else { throw ConfigReadFailure(reason: "out_of_range") }
    return number
}

private func configBool(_ value: JCS.Value) throws -> Bool {
    guard case .bool(let flag) = value else { throw ConfigReadFailure(reason: "wrong_type") }
    return flag
}

extension ConfigKey where Value == String {
    public static func policy(_ name: String, default fallback: String) -> Self { .init(.policy, name, fallback, decode: configString) }
    public static func prompt(_ name: String, default fallback: String) -> Self { .init(.prompts, name, fallback, decode: configString) }
    public static func copy(_ name: String, default fallback: String) -> Self { .init(.copy, name, fallback, decode: configString) }
}

extension ConfigKey where Value == Bool {
    public static func flag(_ name: String, default fallback: Bool) -> Self { .init(.flags, name, fallback, decode: configBool) }
    public static func policy(_ name: String, default fallback: Bool) -> Self { .init(.policy, name, fallback, decode: configBool) }
}

extension ConfigKey where Value == Int64 {
    public static func policy(_ name: String, default fallback: Int64, range: ClosedRange<Int64>? = nil) -> Self {
        .init(.policy, name, fallback) { try configInteger($0, range) }
    }
}

extension ConfigKey where Value == [String] {
    public static func policy(_ name: String, default fallback: [String]) -> Self {
        .init(.policy, name, fallback) { value in
            guard case .array(let items) = value else { throw ConfigReadFailure(reason: "wrong_type") }
            return try items.map(configString)
        }
    }
}

extension ConfigKey where Value == [String: String] {
    public static func policy(_ name: String, default fallback: [String: String]) -> Self {
        .init(.policy, name, fallback) { value in
            guard case .object(let members) = value else { throw ConfigReadFailure(reason: "wrong_type") }
            return try members.mapValues(configString)
        }
    }
}

extension ConfigKey where Value == [String: Int64] {
    public static func policy(_ name: String, default fallback: [String: Int64], range: ClosedRange<Int64>? = nil) -> Self {
        .init(.policy, name, fallback) { value in
            // Every member's type is checked before any range, so the reason never depends on member order.
            guard case .object(let members) = value,
                  members.values.allSatisfy({ if case .integer = $0 { return true } else { return false } }) else {
                throw ConfigReadFailure(reason: "wrong_type")
            }
            return try members.mapValues { try configInteger($0, range) }
        }
    }
}

/// P6a / CORE-PLAN §1.2, §3.3, §4, §8 step 6. Typed `config.policy`, `config.prompts`, `config.copy` and
/// `config.flags` from the verified current bundle in `UpdateStore`, falling back to the compiled default per
/// key. Reads only what is already on disk: it never fetches, so with no bundle (or an unreachable host,
/// which leaves the store as it was) every key is its compiled default, exactly as before this existed.
///
/// A snapshot: build a new one after the update client switches bundles. Each fallback with a reason is
/// logged once and kept in `reports`.
public final class ConfigStore: @unchecked Sendable {
    public typealias Log = @Sendable (ConfigReport) -> Void

    /// Bundle the values come from; nil when none is installed.
    public let bundleVersion: Int64?
    /// What the decoder refused, in decode order (SCHEMAS.md §12).
    public let decodeReports: [ConfigReport]
    private let documents: ConfigDocuments
    private let log: Log
    private let lock = NSLock()
    private var logged: [ConfigReport] = []
    private var seen: Set<ConfigReport> = []

    public static let systemLog: Log = { report in
        #if canImport(os)
        Logger(subsystem: "com.konrad.agentapp", category: "config").notice("\(report.description, privacy: .public)")
        #endif
    }

    /// Compiled defaults only: what an app with no update service configured reads.
    public convenience init(log: @escaping Log = ConfigStore.systemLog) {
        self.init(components: [], bundleVersion: nil, log: log)
    }

    /// The `config` components of the current bundle, each re-checked against its record and the archive rules.
    public convenience init(updates: UpdateStore, log: @escaping Log = ConfigStore.systemLog) {
        let record = updates.record(.current)
        let components = (record?.components ?? []).filter { $0.kind == "config" && $0.contentClass == "data" }
            .map { ConfigComponent(name: $0.name, archive: updates.component($0.name)) }
        self.init(components: components, bundleVersion: record?.bundleVersion, log: log)
    }

    init(components: [ConfigComponent], bundleVersion: Int64?, log: @escaping Log) {
        self.bundleVersion = bundleVersion
        self.log = log
        documents = ConfigDecoder.decode(components)
        decodeReports = documents.reports
        for report in decodeReports { note(report) }
    }

    /// Every fallback with a reason seen so far: decode reports, then read reports in first-seen order.
    public var reports: [ConfigReport] { lock.withLock { logged } }

    /// The bundle's value for `key`, or its compiled default when absent, refused by the decoder, of the
    /// wrong type or out of range (logged), or killed by a `kill.<domain>.<key>` flag (logged).
    public func value<Value>(_ key: ConfigKey<Value>) -> Value {
        if isKilled(key.domain, key.name) {
            note(ConfigReport(reason: "killed", domain: key.domain.rawValue, key: key.name))
            return key.fallback
        }
        guard let raw = documents.values[key.domain]?[key.name] else { return key.fallback }
        do { return try key.decode(raw) } catch {
            let reason = (error as? ConfigReadFailure)?.reason ?? "wrong_type"
            note(ConfigReport(reason: reason, domain: key.domain.rawValue, key: key.name))
            return key.fallback
        }
    }

    /// `kill.<domain>.<key>` is true: that key reads its compiled default.
    public func isKilled(_ domain: ConfigDomain, _ key: String) -> Bool {
        documents.killedKeys.contains(domain.rawValue + "." + key)
    }

    /// `kill.view.<type>` is true: renderers (P7) use the compiled fallback for every view of this type.
    public func isViewKilled(_ type: String) -> Bool { documents.killedViews.contains(type) }

    private func note(_ report: ConfigReport) {
        let isNew = lock.withLock { () -> Bool in
            guard seen.insert(report).inserted else { return false }
            logged.append(report)
            return true
        }
        if isNew { log(report) }
    }
}
