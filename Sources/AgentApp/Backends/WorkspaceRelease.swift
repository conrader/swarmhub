import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A workspace release as the releases page publishes it: `workspace-manifest.json`, its signature beside it
/// (`.sig`, Ed25519 over the manifest's bytes, by the key the app's own updates are signed with: `SUPublicEDKey`)
/// and one program per kind of machine. The app reads it for two things: to say that a newer workspace is out when a
/// server cannot reach the releases itself, and then to fetch the program and hand it to that server
/// (`HerdrClient.uploadUpdate`). The server checks the signature and the digest again; the app checks them first so
/// that nothing unsigned is even sent.
struct WorkspaceRelease: Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable { let target: String; let name: String; let size: Int; let sha256: String }
    struct Manifest: Decodable, Equatable, Sendable {
        let product: String; let version: String; let api: Int; let apiMin: Int
        var released: String? = nil, notes: String? = nil, base: String? = nil
        let assets: [Asset]
    }

    enum Failure: LocalizedError, Equatable {
        case unreachable, unsigned, unreadable, noProgram(String), elsewhere, mismatch
        var errorDescription: String? {
            switch self {
            case .unreachable: "Neither the server nor this Mac could reach the \(AppConstants.name) releases. Try again when one of them is online."
            case .unsigned: "The update is not signed with the \(AppConstants.name) release key, so it was not installed."
            case .unreadable: "The update's description could not be read, so it was not installed."
            case .noProgram(let target): "The release has no program for this kind of machine (\(target))."
            case .elsewhere: "The update points somewhere other than the \(AppConstants.name) releases, so it was not installed."
            case .mismatch: "The downloaded program is not the one the signed release describes, so it was not installed."
            }
        }
    }

    static let manifestName = "workspace-manifest.json"
    static let product = "swarmhub-herdr"
    /// Where the newest manifest is, and the only place it may send the app for the program.
    static let feed = "https://github.com/\(AppConstants.releasesRepo)/releases/latest/download/"
    static let assets = "https://github.com/\(AppConstants.releasesRepo)/releases/download/"
    /// A mirror or a check's local folder (`SWARMHUB_WORKSPACE_FEED`): https, or http on this Mac. The signature is
    /// checked all the same.
    static func mirror(_ setting: String?) -> String? {
        guard let setting, !setting.isEmpty, setting.rangeOfCharacter(from: CharacterSet(charactersIn: "?#@ ")) == nil,
              setting.hasPrefix("https://") || setting.hasPrefix("http://127.0.0.1:") || setting.hasPrefix("http://localhost:") else { return nil }
        return setting.hasSuffix("/") ? setting : setting + "/"
    }

    let manifestData: Data
    let signature: String
    let manifest: Manifest

    func asset(for target: String) -> Asset? { manifest.assets.first { $0.target == target } }

    /// Where the program for `target` is: under the releases, or in the mirror the manifest came from.
    func programURL(for target: String, mirror: String? = nil) throws -> URL {
        guard let asset = asset(for: target) else { throw Failure.noProgram(target) }
        if let mirror, let url = URL(string: mirror + asset.name) { return url }
        guard let base = manifest.base, base.hasPrefix(Self.assets), base.hasSuffix("/"), !base.contains(".."), let url = URL(string: base + asset.name) else { throw Failure.elsewhere }
        return url
    }

    /// What a server that could not look itself is told: the same answer its own check would give.
    func check(current: String, target: String?) -> HerdrClient.UpdateCheck {
        let newer = (SemanticVersion(manifest.version)).flatMap { latest in SemanticVersion(current).map { latest > $0 } } ?? false
        return HerdrClient.UpdateCheck(current: current, available: newer,
            latest: .init(version: manifest.version, api: manifest.api, apiMin: manifest.apiMin, released: manifest.released, notes: manifest.notes,
                          installable: target.map { asset(for: $0) != nil }))
    }

    private static func sane(_ manifest: Manifest) -> Bool {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let parts = manifest.version.split(separator: ".", omittingEmptySubsequences: false)
        return manifest.product == product && parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && Int($0) != nil } && manifest.api >= manifest.apiMin
            && manifest.assets.allSatisfy { asset in
                !asset.name.isEmpty && asset.name.count <= 128 && !asset.name.hasPrefix(".") && asset.name.unicodeScalars.allSatisfy(plain.contains)
                    && asset.size > 0 && asset.sha256.count == 64 && asset.sha256.allSatisfy(\.isHexDigit)
            }
    }

    #if canImport(CryptoKit)
    /// The release, once the signature over exactly these bytes is the release key's and its contents are sane.
    static func verified(manifest data: Data, signature: String, publicKey: String) throws -> WorkspaceRelease {
        guard let key = Data(base64Encoded: publicKey), let signed = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: key), verifier.isValidSignature(signed, for: data) else { throw Failure.unsigned }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let manifest = try? decoder.decode(Manifest.self, from: data), sane(manifest) else { throw Failure.unreadable }
        return WorkspaceRelease(manifestData: data, signature: signature.trimmingCharacters(in: .whitespacesAndNewlines), manifest: manifest)
    }

    static func matches(_ program: Data, _ asset: Asset) -> Bool {
        program.count == asset.size && SHA256.hash(data: program).map { String(format: "%02x", $0) }.joined() == asset.sha256.lowercased()
    }

    /// The release key this app trusts: the one its own updates are checked against.
    static var bundledKey: String { Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? "" }

    /// The newest release, read and checked on this Mac.
    static func latest(session: URLSession = .shared, publicKey: String = bundledKey,
                       mirror: String? = mirror(ProcessInfo.processInfo.environment["SWARMHUB_WORKSPACE_FEED"])) async throws -> WorkspaceRelease {
        let folder = mirror ?? feed
        guard let manifestURL = URL(string: folder + manifestName), let signatureURL = URL(string: folder + manifestName + ".sig") else { throw Failure.unreachable }
        let manifest = try await fetch(manifestURL, limit: 64 * 1024, session: session)
        let signature = try await fetch(signatureURL, limit: 1024, session: session)
        return try verified(manifest: manifest, signature: String(decoding: signature, as: UTF8.self), publicKey: publicKey)
    }

    /// The program for `target`, checked against the signed manifest.
    func program(for target: String, session: URLSession = .shared,
                 mirror: String? = mirror(ProcessInfo.processInfo.environment["SWARMHUB_WORKSPACE_FEED"])) async throws -> Data {
        guard let asset = asset(for: target) else { throw Failure.noProgram(target) }
        let program = try await Self.fetch(try programURL(for: target, mirror: mirror), limit: asset.size, session: session)
        guard Self.matches(program, asset) else { throw Failure.mismatch }
        return program
    }

    private static func fetch(_ url: URL, limit: Int, session: URLSession) async throws -> Data {
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 600)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false, data.count <= limit else { throw Failure.unreachable }
        return data
    }
    #endif
}
