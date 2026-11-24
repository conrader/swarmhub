import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HerdrVault {
    struct Entry: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let revision: Int64
    }

    struct Listing: Decodable, Sendable {
        let configured: Bool
        let entries: [Entry]
    }

    struct Request: Decodable, Identifiable, Sendable {
        let id: String
        let bot: String
        let name: String
        let label: String
        let description: String
        let needsValue: Bool
    }

    enum Decision: Sendable {
        case save(String?)
        case allowRepeated(String?)
        case cancel

        var body: [String: Any] {
            switch self {
            case .save(let value?): ["action": "save", "value": value]
            case .save(nil): ["action": "save"]
            case .allowRepeated(let value?): ["action": "allow_repeated", "value": value]
            case .allowRepeated(nil): ["action": "allow_repeated"]
            case .cancel: ["action": "cancel"]
            }
        }
    }

    static func path(_ id: String, under route: String) throws -> String {
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HerdrClient.Failure.invalidURL
        }
        return route + "/" + id
    }
}

extension HerdrClient {
    func vaultListing() async throws -> HerdrVault.Listing {
        try await get("/api/vault", timeout: 8)
    }

    func vaultRequests() async throws -> [HerdrVault.Request] {
        try await get("/api/vault/requests", timeout: 5)
    }

    func vaultDecide(_ pending: HerdrVault.Request, _ decision: HerdrVault.Decision) async throws {
        let path = try HerdrVault.path(pending.id, under: "/api/vault/requests")
        try await vaultWrite(path, decision.body)
    }

    func vaultAdd(name: String, value: String) async throws {
        try await vaultWrite("/api/vault", ["name": name, "value": value])
    }

    func vaultRename(_ entry: HerdrVault.Entry, name: String) async throws {
        let path = try HerdrVault.path(entry.id, under: "/api/vault")
        try await vaultWrite(path + "/rename", ["name": name, "revision": entry.revision])
    }

    func vaultRemove(_ entry: HerdrVault.Entry) async throws {
        let path = try HerdrVault.path(entry.id, under: "/api/vault")
        try await vaultWrite(path + "/remove", ["revision": entry.revision])
    }

    private func vaultWrite(_ path: String, _ body: [String: Any]) async throws {
        guard baseURL.scheme == "https" || ["127.0.0.1", "localhost"].contains(baseURL.host?.lowercased() ?? "") else {
            throw Failure.http(0, "Open this workspace over HTTPS or a local SSH tunnel to use the Vault.")
        }
        var request = try self.request(path, method: "POST", body: JSONSerialization.data(withJSONObject: body), timeout: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: prepared(request), delegate: HerdrVaultNoRedirect())
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.failure(status: code, body: data) }
    }
}

private final class HerdrVaultNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
