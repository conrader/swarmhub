import Foundation
import CryptoKit
@testable import SwarmHubCore

/// In-process static update host keyed by a unique host per test, so parallel tests never share state.
final class UpdateHostProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case body(Data)
        case status(Int)
        /// Reports a 3xx with this Location and never finishes the original body.
        case redirect(String)
        case fail(URLError.Code)
    }
    typealias Route = @Sendable (String) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static func serve(_ route: @escaping Route) -> (host: String, session: URLSession) {
        let host = "updates-\(UUID().uuidString.lowercased()).test"
        lock.withLock { routes[host] = route }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHostProtocol.self]
        return (host, URLSession(configuration: configuration))
    }
    static func requests(_ host: String) -> [URLRequest] { lock.withLock { seen[host] ?? [] } }
    static func paths(_ host: String) -> [String] { requests(host).compactMap { $0.url?.path } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        let route = Self.lock.withLock { () -> Route? in
            Self.seen[host, default: []].append(request)
            return Self.routes[host]
        }
        switch route?(request.url?.path ?? "") ?? .status(404) {
        case .body(let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let target = URL(string: location, relativeTo: request.url)!.absoluteURL
            let redirect = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
    override func stopLoading() {}
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ text: String = "2026-10-20T12:00:00Z") { date = try! Date(text, strategy: .iso8601) }
    var now: Date { lock.withLock { date } }
    func set(_ text: String) { lock.withLock { date = try! Date(text, strategy: .iso8601) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

struct TestStop: Error {}

enum UpdateFixtures {
    static func data(_ path: String) -> Data {
        (try? Data(contentsOf: UpdateVerifierTests.fixtures.appendingPathComponent(path))) ?? Data()
    }
    /// Component digests of `bundles/11.json`, read from the signed fixture rather than copied.
    static func digest(_ name: String) -> String {
        guard case .object(let envelope)? = try? JCS.parse(data("bundles/11.json")),
              case .object(let signed)? = envelope["signed"], case .array(let components)? = signed["components"] else { return "" }
        for case .object(let component) in components where component["name"] == .string(name) {
            if case .string(let sha)? = component["sha256"] { return sha }
        }
        return ""
    }
    static func blob(_ name: String) -> Data { data("blobs/sha256/" + digest(name)) }
    static let boxComponents = ["swarmhub-manager", "swarmhub-feedback", "swarm-tools", "box-prompts"]

    /// The valid chain, with per-path overrides.
    static func route(_ overrides: [String: UpdateHostProtocol.Reply] = [:]) -> UpdateHostProtocol.Route {
        { path in
            if let reply = overrides[path] { return reply }
            let file: String
            switch path {
            case "/keys.json": file = "keys/keys-2.json"
            case "/channels/stable.json": file = "channels/stable.json"
            case "/bundles/11.json": file = "bundles/11.json"
            default:
                guard path.hasPrefix("/blobs/sha256/") else { return .status(404) }
                file = String(path.dropFirst())
            }
            let bytes = data(file)
            return bytes.isEmpty ? .status(404) : .body(bytes)
        }
    }

    static func configuration(host: String, platform: String = "ios", interval: TimeInterval = 6 * 3600) -> UpdateConfiguration {
        UpdateConfiguration(baseURL: URL(string: "https://\(host)/")!, platform: platform,
                            versions: ["app": "0.6.2", "config_schema": "2", "ui_catalog": "1.3"],
                            pins: data("keys/pins.json"),
                            baseline: UpdateFloors(keysVersion: 1, indexSequence: 4, bundleVersion: 10),
                            installID: "TEST-install-0001", interval: interval, timeout: 5)
    }

    static func temporaryStore() -> UpdateStore {
        UpdateStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("swarmhub-p4a-\(UUID().uuidString)", isDirectory: true))
    }

    /// A store-level snapshot standing in for an earlier verified bundle. Not signed: the store does not verify.
    static func synthetic(_ version: Int64, platform: String = "ios") -> UpdateSnapshot {
        let blob = Data("synthetic policy \(version)\n".utf8)
        let manifest = Data("{\"synthetic\":\(version)}".utf8)
        let record = UpdateRecord(bundleVersion: version, manifestSHA256: updateDigest(manifest),
            appliedAt: "2026-10-01T00:00:00Z", platform: platform,
            components: [.init(name: "policy", kind: "config", contentClass: "data", version: "1.0.\(version)",
                               sha256: updateDigest(blob), size: Int64(blob.count))])
        return UpdateSnapshot(record: record, keys: Data("{}".utf8), index: Data("{}".utf8), manifest: manifest,
                              blobs: ["policy": blob])
    }

    // MARK: Re-signed variants (TEST keys only, built at test time; the fixture files stay as they are)

    /// The `signed` object of a fixture envelope.
    static func signedObject(_ path: String) -> [String: JCS.Value] {
        guard case .object(let envelope)? = try? JCS.parse(data(path)),
              case .object(let signed)? = envelope["signed"] else { return [:] }
        return signed
    }

    /// An envelope over `signed` by one TEST key, its seed read from `keys/TEST-keys.json`.
    static func sign(_ signed: [String: JCS.Value], by keyID: String) -> Data {
        guard case .object(let listing)? = try? JCS.parse(data("keys/TEST-keys.json")),
              case .array(let keys)? = listing["keys"] else { return Data() }
        var seed = ""
        for case .object(let key) in keys where key["key_id"] == .string(keyID) {
            if case .string(let text)? = key["seed"] { seed = text }
        }
        guard seed.count == 64, let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: hexBytes(seed)),
              let canonical = try? JCS.canonical(.object(signed)),
              let signature = try? privateKey.signature(for: Data("swarmhub-signature/1\n".utf8) + canonical) else { return Data() }
        let hex = signature.map { String(format: "%02x", $0) }.joined()
        let envelope: [String: JCS.Value] = ["signed": .object(signed),
                                             "signatures": .array([.object(["key_id": .string(keyID), "sig": .string(hex)])])]
        return (try? JCS.canonical(.object(envelope))) ?? Data()
    }

    /// Bundle 11's signed manifest at another version, with `change` applied to the named component.
    static func manifest(_ version: Int64, component name: String? = nil,
                         change: (inout [String: JCS.Value]) -> Void = { _ in }) -> Data {
        var signed = signedObject("bundles/11.json")
        signed["version"] = .integer(version)
        if let name, case .array(let components)? = signed["components"] {
            signed["components"] = .array(components.map { value in
                guard case .object(var component) = value, component["name"] == .string(name) else { return value }
                change(&component)
                return .object(component)
            })
        }
        return sign(signed, by: "TEST-release-1")
    }

    /// `channels/stable.json` at `seq`, its only line naming `manifest` as bundle `version`.
    static func index(seq: Int64, version: Int64, manifest: Data) -> Data {
        var signed = signedObject("channels/stable.json")
        signed["seq"] = .integer(seq)
        guard case .array(let lines)? = signed["lines"], case .object(var line)? = lines.first else { return Data() }
        line["bundle_version"] = .integer(version)
        line["manifest_sha256"] = .string(updateDigest(manifest))
        signed["lines"] = .array([.object(line)])
        return sign(signed, by: "TEST-release-1")
    }

    /// `keys/keys-2.json` at version 3 without TEST-release-1: the release key that signs the index is revoked.
    static func keysRevokingRelease1() -> Data {
        var signed = signedObject("keys/keys-2.json")
        signed["version"] = .integer(3)
        if case .array(let keys)? = signed["keys"] {
            signed["keys"] = .array(keys.filter { value in
                guard case .object(let key) = value else { return true }
                return key["key_id"] != .string("TEST-release-1")
            })
        }
        return sign(signed, by: "TEST-root-1")
    }

    /// Every file and link under the store except state.json: file bytes, link destinations, permissions.
    static func tree(_ store: UpdateStore) -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        for path in fm.enumerator(atPath: store.root.path)?.compactMap({ $0 as? String }) ?? [] where path != "state.json" {
            let full = store.root.appendingPathComponent(path).path
            guard let attributes = try? fm.attributesOfItem(atPath: full) else { continue }
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?: result[path] = "link:" + ((try? fm.destinationOfSymbolicLink(atPath: full)) ?? "?")
            case .typeRegular?:
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
                result[path] = "file:\(String(mode, radix: 8)):" + updateDigest((try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data())
            default: continue
            }
        }
        return result
    }
}
