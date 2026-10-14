import Foundation

/// The address a person types for their box, made usable: trimmed, `https://` added when no scheme was typed, the
/// trailing `/` dropped. `HermesBackend` already strips a `/v1` suffix itself.
enum BoxAddress {
    static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func url(_ text: String) -> URL? { HermesBackend.validatedBaseURL(normalize(text)) }

    static func isLoopback(_ url: URL) -> Bool { ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") }

    /// "this Mac" for a loopback address, otherwise the host name.
    static func place(_ url: URL) -> String { isLoopback(url) ? SetupCopy.thisMac : url.host ?? url.absoluteString }
}

/// What the person typed on the address step (S3). The key is empty when re-running on a configured app (D7: keep).
struct SetupInput: Equatable, Sendable {
    var address = ""
    var key = ""
    /// The folded "I have more than one agent" box: one `name=key` per line (`HermesKeyPaste`).
    var extra = ""
}

/// The result of Test: one plain outcome, plus what the commit needs (no second network call).
struct SetupCheckResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case badAddress, notEncrypted(port: Int?), unreachable, keyRejected, mainOnly(String), noAgents, badLine
        case connected(place: String, count: Int)
    }
    var outcome: Outcome
    var baseURL: URL?
    var probes: [HermesProfileProbe] = []
    /// Extra agents' keys by name, from the fold; written only on Add.
    var extraKeys: [String: String] = [:]

    var available: [HermesAgentProfile] { probes.compactMap { if case .available(let profile) = $0.status { profile } else { nil } } }
    var succeeded: Bool { if case .connected = outcome { true } else { false } }
    var message: String { SetupCheck.message(outcome) }
    /// Plain lines for the extra agents that were not found (shown under the list on S4).
    var problems: [String] {
        probes.compactMap { probe in
            switch probe.status {
            case .available: nil
            case .prefixIgnored: SetupCopy.mainOnly(HermesProfileNaming.botName(forProfile: probe.id))
            case .unavailable: probe.id == "default" ? nil : SetupCopy.notAdded(HermesProfileNaming.botName(forProfile: probe.id))
            }
        }
    }
}

/// Test on the setup window: entirely in memory (P21 item 13). Reads the box's health and each agent's model list;
/// writes nothing to the key store, the settings or the store file. No message ever contains a key.
enum SetupCheck {
    static func run(_ input: SetupInput, savedKey: @Sendable () -> String = { "" }, session: URLSession = TestRunGuard.sharedSession) async -> SetupCheckResult {
        guard let baseURL = BoxAddress.url(input.address) else { return .init(outcome: .badAddress) }
        let parsed = HermesKeyPaste.parse(input.extra)
        guard parsed.invalid.isEmpty else { return .init(outcome: .badLine, baseURL: baseURL) }
        let extraKeys = Dictionary(parsed.entries.map { ($0.profile, $0.key) }, uniquingKeysWith: { _, last in last })
        let key = input.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? savedKey() : input.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = [key] + Array(extraKeys.values)
        guard keys.allSatisfy({ HermesBackend.permitsAPIKey($0, at: baseURL) }) else {
            return .init(outcome: .notEncrypted(port: baseURL.port), baseURL: baseURL)
        }
        let backend = HermesBackend(baseURL: baseURL, apiKey: key, session: session)
        do { _ = try await backend.testConnection() } catch {
            return .init(outcome: outcome(for: error), baseURL: baseURL)
        }
        let probes = await backend.probeProfiles(named: parsed.entries.map(\.profile), keyFor: { extraKeys[$0] ?? "" })
        var result = SetupCheckResult(outcome: .noAgents, baseURL: baseURL, probes: probes, extraKeys: extraKeys)
        let count = result.available.count
        if count > 0 { result.outcome = .connected(place: BoxAddress.place(baseURL), count: count) }
        else if probes.contains(where: { $0.httpStatus == 401 || $0.httpStatus == 403 }) { result.outcome = .keyRejected }
        else if let ignored = probes.first(where: { $0.status == .prefixIgnored }) { result.outcome = .mainOnly(HermesProfileNaming.botName(forProfile: ignored.id)) }
        return result
    }

    static func outcome(for error: Error) -> SetupCheckResult.Outcome {
        if case BackendError.http(let code, _) = error, code == 401 || code == 403 { return .keyRejected }
        if case BackendError.invalidURL = error { return .badAddress }
        return .unreachable
    }

    static func message(_ outcome: SetupCheckResult.Outcome) -> String {
        switch outcome {
        case .badAddress: SetupCopy.badAddress
        case .notEncrypted(let port): SetupCopy.notEncrypted(port: port)
        case .unreachable: SetupCopy.unreachable
        case .keyRejected: SetupCopy.keyRejected
        case .mainOnly(let name): SetupCopy.mainOnly(name)
        case .noAgents: SetupCopy.noAgents
        case .badLine: SetupCopy.badLine
        case .connected(let place, let count): SetupCopy.connected(to: place, found: count)
        }
    }
}
