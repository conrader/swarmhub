import Foundation

/// P12: one saved OpenClaw Gateway. JSON in UserDefaults (`openClawGateways`), never a secret: the token, device token
/// and device key live in the Keychain under `openclaw.<id>.token`, `.device-token` and `.device-key`.
struct OpenClawGateway: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var url: String
    /// Plaintext `ws://` to a private-network host (RFC 1918, link-local, CGNAT, `.local`), and a token over it.
    var allowPrivatePlaintext = false
    var deviceName: String = OpenClawGateway.defaultDeviceName
    /// Keep the shared Gateway token after pairing (normally it leaves the Keychain once the device token is stored).
    var keepsToken = false

    static let defaultDeviceName = "\(AppConstants.name) (Mac)"
    var tokenAccount: String { "openclaw.\(id).token" }
    var deviceTokenAccount: String { "openclaw.\(id).device-token" }
    var deviceKeyAccount: String { GatewayIdentity.account(gatewayID: id) }
    var accounts: [String] { [tokenAccount, deviceTokenAccount, deviceKeyAccount] }
}

/// The URL rules, pure. `http`/`https` map to `ws`/`wss`; no user-info, query or fragment; port 18789 when a `ws` URL
/// has none. Plaintext is allowed for loopback; other private hosts need `allowPrivatePlaintext`; anything else `wss://`.
enum GatewayURLRules {
    static let defaultPort = 18789

    enum HostClass: Equatable { case loopback, privateNetwork, publicHost }

    enum Problem: LocalizedError, Equatable {
        case invalid, scheme, userInfo, queryOrFragment, plaintextPrivate, plaintextPublic
        var errorDescription: String? {
            switch self {
            case .invalid: "Enter the Gateway address, for example ws://127.0.0.1:18789."
            case .scheme: "The Gateway address starts with ws:// or wss://."
            case .userInfo: "Leave the user name and password out of the address; put the token in its own field."
            case .queryOrFragment: "The Gateway address has no ? or # part."
            case .plaintextPrivate: "This is a private-network address over plain ws://. Tick “Allow plain ws:// on my private network”, or use wss://."
            case .plaintextPublic: "Plain ws:// is only allowed for this Mac or a private network. Use wss:// (for example Tailscale Serve) or an SSH tunnel to ws://127.0.0.1:18789."
            }
        }
    }

    /// The normalised URL, or why it is refused.
    static func validate(_ text: String, allowPrivatePlaintext: Bool) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return .failure(.invalid) }
        switch scheme {
        case "ws", "http": components.scheme = "ws"
        case "wss", "https": components.scheme = "wss"
        default: return .failure(.scheme)
        }
        guard components.user == nil, components.password == nil else { return .failure(.userInfo) }
        guard components.query == nil, components.fragment == nil else { return .failure(.queryOrFragment) }
        if components.scheme == "ws" {
            if components.port == nil { components.port = defaultPort }
            switch hostClass(host) {
            case .loopback: break
            case .privateNetwork: if !allowPrivatePlaintext { return .failure(.plaintextPrivate) }
            case .publicHost: return .failure(.plaintextPublic)
            }
        }
        if components.path == "/" { components.path = "" }
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    static func hostClass(_ rawHost: String) -> HostClass {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return .loopback }
        if let octets = ipv4(host) {
            switch (octets[0], octets[1]) {
            case (127, _): return .loopback
            case (10, _), (192, 168), (169, 254): return .privateNetwork
            case (172, 16...31), (100, 64...127): return .privateNetwork
            default: return .publicHost
            }
        }
        if host.contains(":") { // IPv6 literal: link-local fe80::/10 and unique-local fc00::/7
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") || host.hasPrefix("fc") || host.hasPrefix("fd") { return .privateNetwork }
            return .publicHost
        }
        if host.hasSuffix(".local") { return .privateNetwork }
        return .publicHost
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }.filter { (0...255).contains($0) }
        return octets.count == 4 && parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) ? octets : nil
    }

    static func isLoopback(_ url: URL) -> Bool { url.host.map { hostClass($0) == .loopback } ?? false }
    /// Where a stored device token may be retried after `AUTH_TOKEN_MISMATCH`: loopback or `wss://`.
    static func isTrusted(_ url: URL) -> Bool { url.scheme == "wss" || isLoopback(url) }
    /// A token goes in plaintext only to loopback, or to a private host the user ticked.
    static func permitsToken(_ url: URL, allowPrivatePlaintext: Bool) -> Bool {
        if url.scheme == "wss" || isLoopback(url) { return true }
        return allowPrivatePlaintext && url.host.map { hostClass($0) == .privateNetwork } == true
    }
}

/// The saved Gateways (UserDefaults JSON) and their Keychain items.
struct GatewayStore {
    static let defaultsKey = "openClawGateways"
    static let legacyURLKey = "openClawURL"
    let defaults: UserDefaults
    let keyStore: any HermesKeyStore

    func load() -> [OpenClawGateway] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([OpenClawGateway].self, from: data)) ?? []
    }

    func save(_ gateways: [OpenClawGateway]) {
        defaults.set(try? JSONEncoder().encode(gateways), forKey: Self.defaultsKey)
    }

    /// Once: the pre-P12 `openClawURL` default becomes a Gateway named "OpenClaw" without a token; the key is removed.
    @discardableResult func migrateLegacyURL() -> OpenClawGateway? {
        guard let legacy = defaults.string(forKey: Self.legacyURLKey) else { return nil }
        defaults.removeObject(forKey: Self.legacyURLKey)
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var gateways = load()
        guard !gateways.contains(where: { $0.url == trimmed }) else { return nil }
        let gateway = OpenClawGateway(name: "OpenClaw", url: trimmed)
        gateways.append(gateway); save(gateways)
        return gateway
    }

    /// Adds or replaces by id. A changed URL drops the stored device token (it belongs to the old endpoint).
    func upsert(_ gateway: OpenClawGateway) {
        var gateways = load()
        if let index = gateways.firstIndex(where: { $0.id == gateway.id }) {
            if gateways[index].url != gateway.url { keyStore.setKey("", for: gateway.deviceTokenAccount) }
            gateways[index] = gateway
        } else { gateways.append(gateway) }
        save(gateways)
    }

    /// Deletes the three Keychain items and the entry.
    func forget(_ gateway: OpenClawGateway) {
        gateway.accounts.forEach { keyStore.setKey("", for: $0) }
        save(load().filter { $0.id != gateway.id })
    }
}

/// One Gateway's secrets as the connection uses them; every value stays inside this type and the Keychain.
struct GatewayCredentials: Sendable {
    let gateway: OpenClawGateway
    let keyStore: any HermesKeyStore

    var sharedToken: String { keyStore.key(for: gateway.tokenAccount) }
    var deviceToken: String { keyStore.key(for: gateway.deviceTokenAccount) }
    /// The three secrets, for the redactor.
    var secrets: [String] { [sharedToken, deviceToken, keyStore.key(for: gateway.deviceKeyAccount)].filter { !$0.isEmpty } }

    /// Written once, on Save; blank means Tailscale or proxy identity (nothing stored).
    func setSharedToken(_ token: String) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        keyStore.setKey(value, for: gateway.tokenAccount)
    }

    /// Persist `hello-ok.auth.deviceToken`: write, read back, and only then drop the shared token (unless kept).
    @discardableResult func storeDeviceToken(_ token: String) -> Bool {
        guard keyStore.storeVerified(token, for: gateway.deviceTokenAccount) else { return false }
        if !gateway.keepsToken, !sharedToken.isEmpty { keyStore.setKey("", for: gateway.tokenAccount) }
        return true
    }

    func dropDeviceToken() { keyStore.setKey("", for: gateway.deviceTokenAccount) }
}

/// Every error string shown for OpenClaw passes here: the token, device token and private key never appear.
enum GatewayRedactor {
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 4 }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
}
