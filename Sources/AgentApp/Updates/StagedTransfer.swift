import Foundation

/// Stock Hermes POST /api/sessions stores system_prompt without a model turn (0.21.7 api_server.py).
/// Never chat in these carrier sessions. The destination script reads them using SQLite mode=ro.
struct StagedTransfer: Sendable {
    static let chunkSize = 49_152
    let prefix: String
    let parts: [Data]
    let sha256: String
    var hashes: [String] { parts.map(StagedInstall.digest) }
    var ids: [String] { parts.indices.map { prefix + String($0) } }

    static func completed(_ result: String?, prefix: String) -> Bool {
        guard let result else { return false }
        var output = result
        if let data = result.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            guard (object["exit_code"] as? Int) == 0, let stdout = (object["output"] ?? object["stdout"]) as? String else { return false }
            output = stdout
        }
        return output.split(separator: "\n").last.map(String.init) == "SWARMHUB_TRANSFER_OK:" + prefix
    }

    /// Diagnostics are read only from the matched staging call, even when its terminal exit is nonzero.
    static func failure(_ result: String?, prefix: String, previous: BoxUpdaterStatus?) -> BoxUpdaterStatus? {
        guard let result, result.utf8.count <= 2_097_152 else { return nil }
        var output = result
        if let wrapper = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
           let stdout = (wrapper["output"] ?? wrapper["stdout"]) as? String { output = stdout }
        for line in output.split(separator: "\n").reversed().map(String.init) {
            let updater = "SWARMHUB_UPDATER_RESULT:" + prefix
            let transfer = "SWARMHUB_TRANSFER_FAILED:" + prefix
            if line.hasPrefix(updater),
               let object = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(updater.count).utf8))) as? [String: Any],
               let code = object["exit_code"] as? Int, code != 0, let stdout = object["output"] as? String {
                return BoxUpdaterStatus.failedResult(stdout, previous: previous)
            }
            if line.hasPrefix(transfer),
               let detail = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(transfer.count).utf8)) {
                return .failure("Transfer failed: " + detail, previous: previous)
            }
        }
        return nil
    }

    init(_ package: StagedInstall.Package, namespace: String = "") throws {
        guard namespace.range(of: #"\A[A-Za-z0-9_-]{0,128}\z"#, options: .regularExpression) != nil else {
            throw StagedInstall.Failure.refused("session namespace")
        }
        prefix = namespace + "agentapp_update_bytes_" + UUID().uuidString.lowercased() + "_"
        var files = package.files
        files["profiles.json"] = try JSONEncoder().encode(package.profiles)
        let payload = try JSONEncoder().encode(files.mapValues { $0.base64EncodedString() })
        sha256 = StagedInstall.digest(payload)
        parts = stride(from: 0, to: payload.count, by: Self.chunkSize).map {
            payload.subdata(in: $0..<min($0 + Self.chunkSize, payload.count))
        }
    }

    func upload(to backend: HermesBackend) async throws {
        guard try await backend.sessionTransport() == .nativeSessions else {
            throw StagedInstall.Failure.refused("native Hermes sessions required for byte transport")
        }
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            // Use the raw endpoint: a 409 is a refusal, never acceptance of a pre-existing carrier row.
            let reply = try await backend.jsonRequest(path: "api/sessions", method: "POST", body: [
                "id": ids[index], "source": "api_server", "system_prompt": part.base64EncodedString()
            ])
            guard (reply["session"] as? [String: Any])?["id"] as? String == ids[index] else {
                throw StagedInstall.Failure.refused("carrier session ID mismatch")
            }
        }
    }
}

extension HermesBackend {
    func deleteUpdaterSession(_ id: String) async throws {
        do { _ = try await jsonRequest(path: "api/sessions/\(Self.escapedPath(id))", method: "DELETE") }
        catch BackendError.http(let code, _) where code == 404 { return }
    }
}

extension AppStore {
    /// Persist cleanup before the first upload, including ambiguous delivery and app interruption. Retry on the
    /// next updater action if the box is unreachable. A cancelled stream must not cancel its cleanup requests.
    func cleanUpdaterSessions(on target: String, backend: HermesBackend) async {
        let key = "updates.transport.cleanup." + target
        let ids = defaults.stringArray(forKey: key) ?? []
        // Persisted IDs can belong to an earlier QA/E2E namespace. Match them independently of today's namespace.
        for id in ids where id.range(of: #"\A[A-Za-z0-9_-]*agentapp_update_(bytes|status)_[A-Za-z0-9_-]+\z"#,
                                    options: .regularExpression) != nil {
            if (try? await backend.deleteUpdaterSession(id)) != nil {
                defaults.set((defaults.stringArray(forKey: key) ?? []).filter { $0 != id }, forKey: key)
            }
        }
    }

    func stagedInstallStream(_ request: AgentRequest, transfer: StagedTransfer, target: String,
                             backend: HermesBackend) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        await cleanUpdaterSessions(on: target, backend: backend)
        let key = "updates.transport.cleanup." + target
        guard (defaults.stringArray(forKey: key) ?? []).isEmpty else {
            throw StagedInstall.Failure.refused("temporary session cleanup pending; retry when the box is reachable")
        }
        defaults.set((defaults.stringArray(forKey: key) ?? []) + transfer.ids, forKey: key)
        do {
            try await transfer.upload(to: backend)
            let stream = try await backend.send(request)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in stream { continuation.yield(event) }
                        await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
                        continuation.finish()
                    } catch {
                        await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch {
            await Task { await self.cleanUpdaterSessions(on: target, backend: backend) }.value
            throw error
        }
    }
}
