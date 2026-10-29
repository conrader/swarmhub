import Foundation

/// uxfix1: network trouble that clears up by itself (a dropped or timed-out connection, the Mac offline, the box briefly
/// unreachable, a gateway that answered 502/503/504). It never opens the modal "Backend Error" alert: turns and installs
/// retry it, a turn's row says "Reconnecting…" meanwhile, and what is left after the retries is one small line at the
/// bottom of the window (`ConnectionNoticeBar`) that clears itself when the box answers again.
enum TransientNetwork {
    /// -1005 connection lost, -1001 timed out, -1004 cannot connect, -1009 offline, and the DNS / cellular cases.
    static let codes: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
                                            .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive]
    /// Socket errors a dropped connection reports: EPIPE, ENETDOWN, ENETUNREACH, ECONNABORTED, ECONNRESET, ENOTCONN,
    /// ETIMEDOUT, EHOSTUNREACH.
    static let posixCodes: Set<Int> = [32, 50, 51, 53, 54, 57, 60, 65]
    /// uxfix1-e2e: CFNetwork's own codes for the same trouble, which arrive unbridged (not as URLError): 302 connection
    /// lost, 306 HTTP proxy and 310 HTTPS proxy unreachable, 311 the proxy refused the tunnel (a Mac behind a proxy).
    static let cfNetworkDomain = "kCFErrorDomainCFNetwork"
    /// uxfix3: and 1/2 (host lookup failed) and 308 (the proxy auto-config file could not be read).
    static let cfNetworkCodes: Set<Int> = [1, 2, 302, 306, 308, 310, 311]
    /// The proxy and host codes alone: the request never reached the box.
    static let cfProxyCodes: Set<Int> = [1, 2, 306, 308, 310, 311]
    /// A proxy in front of the box (Cloudflare, nginx) answering while the box restarts.
    static let gatewayStatuses: Set<Int> = [502, 503, 504]

    static func isTransient(_ error: Error) -> Bool {
        if let broken = error as? StreamBreak { return broken.isEndOfStream || isTransient(broken.underlying) }
        if let url = error as? URLError { return codes.contains(url.code) }
        if case BackendError.http(let code, _) = error { return gatewayStatuses.contains(code) }
        if error is BackendError || error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return codes.contains(URLError.Code(rawValue: ns.code)) }
        if ns.domain == NSPOSIXErrorDomain { return posixCodes.contains(ns.code) }
        if ns.domain == cfNetworkDomain, cfNetworkCodes.contains(ns.code) || codes.contains(URLError.Code(rawValue: ns.code)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isTransient(underlying) }
        return false
    }

    /// The words those errors arrive as once only their text reached `errorMessage` (any caller, any prefix): the
    /// English system copy, the copy this Mac's language gives, and the bare "NSURLErrorDomain error -1005." form.
    static let phrases: [String] = {
        var words = ["The network connection was lost.", "The request timed out.", "Could not connect to the server.",
                     "The Internet connection appears to be offline.", "A server with the specified hostname could not be found.",
                     StreamBreak.EndOfStream().localizedDescription]
        words += cfNetworkCodes.sorted().map { "\(cfNetworkDomain) error \($0)." }
        for code in codes {
            words.append("NSURLErrorDomain error \(code.rawValue).")
            words.append("\(cfNetworkDomain) error \(code.rawValue).")
            let text = URLError(code).localizedDescription
            // The generic "The operation couldn't be completed. (… -1005.)" form is covered above; never match all errors.
            if !text.isEmpty, !text.contains(String(code.rawValue)) { words.append(text) }
        }
        var seen: Set<String> = []
        return words.filter { seen.insert($0).inserted }
    }()

    static func isTransient(text: String) -> Bool { phrases.contains { text.localizedCaseInsensitiveContains($0) } }
}
