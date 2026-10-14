import Darwin
import Foundation

/// `AgentApp --check-server <base-url> --profile <name|default> --key-file <path> [--report <file>]`: everything SwarmHub
/// reads from a Hermes server, through the app's real `HermesBackend` (no store, no Keychain). Read-only except one
/// throwaway session (`swarmhub-selftest-vanilla-…`) that is created, deleted and checked gone. Nothing is sent to
/// `/chat`. One `PASS`/`FAIL`/`KNOWN` line per check; the key is never printed. Exit 0 only when no check failed.
@MainActor enum HeadlessCheckServer {
    enum Outcome: String { case pass = "PASS", fail = "FAIL", known = "KNOWN" }

    struct Check: Equatable {
        let id: String; let outcome: Outcome; let detail: String
        var line: String { "\(outcome.rawValue) \(id) | \(detail)" }
    }

    static let usage = "Usage: AgentApp --check-server <base-url> --profile <name|default> --key-file <path> [--report <file>]"
    static let ids = ["health", "auth", "models", "capabilities", "model-options", "skills", "toolsets", "sessions", "jobs", "session-write"]

    static func run(arguments: [String]) -> Int32 {
        guard let raw = value(after: "--check-server", in: arguments), let url = HermesBackend.validatedBaseURL(raw),
              let profile = value(after: "--profile", in: arguments), profile == "default" || HermesKeyPaste.isValidProfileName(profile),
              let keyPath = value(after: "--key-file", in: arguments) else { print(usage); return 64 }
        let key: String
        switch readKey(at: (keyPath as NSString).expandingTildeInPath) {
        case .failure(let error): print("Check failed: \(error.text)"); return 2
        case .success(let value): key = value
        }
        let backend = HermesBackend(baseURL: url, apiKey: key, profile: profile)
        let reportPath = value(after: "--report", in: arguments).map { ($0 as NSString).expandingTildeInPath }
        let header = "== check-server \(url.absoluteString) profile \(profile) key-file \(URL(fileURLWithPath: keyPath).lastPathComponent) at \(ISO8601DateFormatter().string(from: Date()))"
        return HeadlessRunLoop.wait {
            var lines = [header]
            print(header)
            let checks = await run(backend: backend, output: { print($0); fflush(stdout); lines.append($0) })
            if let reportPath, !append(lines, to: reportPath) { print("Warning: could not write the report to \(reportPath)"); return 1 }
            return checks.contains { $0.outcome == .fail } ? 1 : 0
        }
    }

    /// The key file must be a 0600 regular file owned by this user; its one line (trimmed) is the key.
    static func readKey(at path: String) -> Result<String, KeyError> {
        if let problem = HeadlessCommands.checkKeyFile(path) { return .failure(.init(text: "the key file is unusable (\(problem)); it must be a 0600 regular file you own.")) }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return .failure(.init(text: "the key file is not readable UTF-8 text.")) }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isNewline) else { return .failure(.init(text: "the key file must hold exactly one key.")) }
        return .success(key)
    }
    struct KeyError: Error { let text: String }

    // MARK: Checks

    /// Runs every check in `ids` order, printing one line each. Details never contain the key.
    static func run(backend: HermesBackend, tag: String = String(UUID().uuidString.lowercased().prefix(8)), output: (String) -> Void) async -> [Check] {
        var checks: [Check] = []
        func record(_ id: String, _ outcome: Outcome, _ detail: String) {
            let key = backend.apiKey
            let check = Check(id: id, outcome: outcome, detail: key.isEmpty ? detail : detail.replacingOccurrences(of: key, with: "[key]"))
            checks.append(check); output(check.line)
        }
        func failure(_ error: Error) -> String { BotInfoCache.describe(error, key: backend.apiKey) }

        // /health + the P24 compatibility table.
        let reading = await backend.hermesVersion()
        if let version = reading.version, let status = reading.status {
            let issues = HermesCompatibility.issues(for: version).map(\.rawValue).sorted()
            let detail = "\(reading.label) · known issues: \(issues.isEmpty ? "none" : issues.joined(separator: ", "))"
            record("health", status == .notSupported ? .fail : .pass, detail)
        } else { record("health", .fail, reading.problem ?? reading.label) }

        // /v1/models: proves the key (401/403 here is the auth answer) and, for a named profile, multiplexing.
        do {
            let json = try await backend.jsonRequest(path: "v1/models")
            record("auth", .pass, "key accepted for profile \(backend.profile) (GET /v1/models 200)")
            let models = ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            if let first = models.first, backend.profile == "default" || first == backend.profile { record("models", .pass, "\(models.count) listed: \(models.joined(separator: ", "))") }
            else if models.isEmpty { record("models", .fail, "Server listed no models.") }
            else { record("models", .fail, "\(HermesBackend.multiplexOffMessage) (first model \(models[0]))") }
        } catch {
            if case BackendError.http(let code, _) = error, code == 401 || code == 403 { record("auth", .fail, "HTTP \(code): the server rejected this key for profile \(backend.profile)") }
            else { record("auth", .fail, failure(error)) }
            record("models", .fail, failure(error))
        }

        var capabilities: HermesCapabilities?
        do {
            capabilities = try await backend.capabilities()
            if let capabilities {
                let on = capabilities.features.filter(\.value).keys.sorted()
                let transport = capabilities.features["session_chat_streaming"] == true ? "native sessions" : "legacy chat completions"
                record("capabilities", .pass, "\(on.count) features on (\(on.joined(separator: ", "))); \(capabilities.endpoints.count) endpoints; transport \(transport)")
            } else { record("capabilities", .fail, "no /v1/capabilities (404): every optional feature would be hidden") }
        } catch { record("capabilities", .fail, failure(error)) }

        do {
            let catalog = try await backend.modelOptions().catalog(profile: backend.profile)
            let models = catalog.suppliers.reduce(0) { $0 + $1.models.count }
            let fallback = catalog.agentDefault.map { "agent default \($0.supplier.map { "\($0)/" } ?? "")\($0.model)" } ?? "no agent default"
            record("model-options", .pass, "catalog: \(catalog.suppliers.count) suppliers, \(models) models, \(catalog.hiddenCount) setup skeletons hidden; \(fallback)")
        } catch { record("model-options", .fail, failure(error)) }

        do {
            let skills = try await backend.skills()
            record("skills", .pass, "\(skills.count) skills")
        } catch {
            if let issue = HermesCompatibility.limitation(for: error, version: reading.version) { record("skills", .known, "\(issue.rawValue): \(issue.note)") }
            else { record("skills", .fail, failure(error)) }
        }

        do {
            let toolsets = try await backend.toolsets()
            record("toolsets", .pass, "\(toolsets.count) toolsets (\(toolsets.filter { $0.enabled == true }.count) enabled)")
        } catch { record("toolsets", .fail, failure(error)) }

        do {
            guard try await backend.transport() == .nativeSessions else { throw BackendError.unavailable("the server does not advertise session_chat_streaming, so the app lists no sessions") }
            let sessions = try await backend.listSessions()
            record("sessions", .pass, "\(sessions.count) sessions listed (source=api_server)")
        } catch { record("sessions", .fail, failure(error)) }

        do {
            let jobs = try await HermesJobsClient(backend: backend).list()
            record("jobs", .pass, "\(jobs.count) jobs listed (include_disabled)")
        } catch { record("jobs", .fail, failure(error)) }

        let id = "\(AppConstants.selfTestPrefix)vanilla-\(tag)"
        do {
            let created = try await backend.createSession(title: id, systemPrompt: "\(AppConstants.name) server self-check; no turn is sent.", id: id)
            guard created == id else { throw BackendError.unavailable("Hermes created \(created) instead of \(id).") }
            _ = try await backend.sessionModel(sessionID: id)
            let deleted = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(id))", method: "DELETE")
            guard deleted["deleted"] as? Bool != false else { throw BackendError.unavailable("Hermes answered deleted=false for \(id).") }
            do {
                _ = try await backend.sessionModel(sessionID: id)
                record("session-write", .fail, "\(id) still exists after DELETE")
            } catch BackendError.http(404, _) {
                record("session-write", .pass, "created \(id), read it back, deleted it, GET now 404")
            }
        } catch { record("session-write", .fail, "\(id): \(failure(error))") }

        let failed = checks.filter { $0.outcome == .fail }.count, known = checks.filter { $0.outcome == .known }.count
        output("Check-server: \(checks.count - failed - known) passed, \(known) known, \(failed) failed")
        return checks
    }

    // MARK: Report (appended, 0600)

    static func append(_ lines: [String], to path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { return false }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        return data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == data.count
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
