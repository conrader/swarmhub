import Foundation

public struct ConnectionAddress: Codable, Hashable, Sendable {
    public let baseURL: URL
    public let profile: String

    public init(_ text: String, profile: String = "default", allowLoopbackHTTP: Bool = false) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, ["https", "http"].contains(components.scheme?.lowercased() ?? "") else {
            throw CoreError.invalidAddress
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard components.scheme?.lowercased() == "https" || (allowLoopbackHTTP && loopback) else { throw CoreError.insecureAddress }
        guard Self.validProfile(profile) else { throw CoreError.invalidProfile }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        // A profile is supplied separately so it cannot accidentally be applied twice.
        if let range = path.range(of: "/p/", options: .backwards) {
            let embedded = String(path[range.upperBound...])
            guard embedded == profile else { throw CoreError.invalidAddress }
            path = String(path[..<range.lowerBound])
        }
        components.percentEncodedPath = path
        components.scheme = components.scheme?.lowercased()
        guard let url = components.url else { throw CoreError.invalidAddress }
        self.baseURL = url
        self.profile = profile
    }

    public static func validProfile(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0))
        }
    }

    public func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard !path.contains("?"), !path.contains("#"), !path.hasPrefix("/"), !path.contains("..") else {
            throw CoreError.invalidIdentifier
        }
        var root = baseURL
        if profile != "default" { root.appendPathComponent("p"); root.appendPathComponent(profile) }
        for part in path.split(separator: "/") { root.appendPathComponent(String(part)) }
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { throw CoreError.invalidAddress }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw CoreError.invalidAddress }
        return url
    }

    public static func validResourceID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.:".unicodeScalars.contains($0))
        }
    }
}
