import Foundation

/// Which presigned blob URLs Torvli will GET (Rule 1): https only, a DNS host name, no user info, never localhost,
/// a `.local` host or an IP literal (dotted, decimal, hex or IPv6). Anything else is refused without contact.
enum GrokBlobURL {
    static func validated(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host, !rawHost.isEmpty, let url = components.url else { return nil }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":"), !host.hasPrefix("[") else { return nil }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "local" || host.hasSuffix(".local") { return nil }
        // Real top-level domains are never numeric or hex, so this rejects every IPv4 spelling inet_aton accepts.
        guard let last = host.split(separator: ".").last, !last.isEmpty,
              !last.allSatisfy(\.isNumber), !last.hasPrefix("0x") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.allSatisfy({ allowed.contains($0) }) else { return nil }
        return url
    }
}
