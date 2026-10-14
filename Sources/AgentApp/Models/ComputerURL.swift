import Foundation

/// A bot's web desktop (noVNC or similar): https anywhere, plain http only on loopback. Credentials never
/// go in the URL — it is stored in store.json — so user info and password/token query items are refused.
enum ComputerURL {
    enum Check: Equatable { case empty, valid(URL), invalid(String) }

    static func check(_ raw: String) -> Check {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty, let url = components.url else {
            return .invalid("Not a valid URL.")
        }
        guard components.user == nil, components.password == nil else { return .invalid("Remove the user name or password from the URL.") }
        let secretNames: Set<String> = ["password", "passwd", "token", "access_token", "api_key", "apikey", "key"]
        if components.queryItems?.contains(where: { secretNames.contains($0.name.lowercased()) }) == true || secretNames.contains(where: { (components.fragment ?? "").lowercased().contains("\($0)=") }) {
            return .invalid("Remove the password or token from the URL; enter it on the desktop page instead.")
        }
        switch scheme {
        case "https": return .valid(url)
        case "http": return isLoopback(host) ? .valid(url) : .invalid("Use https (plain http is allowed only for localhost).")
        default: return .invalid("Use an https:// address.")
        }
    }

    static func validURL(_ raw: String?) -> URL? {
        if case .valid(let url) = check(raw ?? "") { return url }
        return nil
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "::1" || bare.hasPrefix("127.") && bare.split(separator: ".").count == 4 && bare.split(separator: ".").allSatisfy { UInt8($0) != nil }
    }

    enum Reachability: Equatable { case unknown, checking, reachable(Int), unreachable(String) }

    /// `HEAD` the page with a short timeout. Any HTTP answer (even 401/404) means the host is up.
    static func probe(_ url: URL, session: URLSession = TestRunGuard.sharedSession) async -> Reachability {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable("No HTTP answer.") }
            return .reachable(http.statusCode)
        } catch { return .unreachable(error.localizedDescription) }
    }
}
