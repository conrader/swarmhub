import Foundation
import Network

/// uxfix1-e2e: a loopback HTTPS proxy (HTTP CONNECT tunnels) for `--e2e-live`, so the run can drop the app's
/// connection to the box for real: `drop(for:)` closes every open tunnel (the app sees "The network connection was
/// lost.") and, until the time is up, closes each new tunnel as soon as it opens (the same, never a failed proxy). Only `allowedHost:443` is
/// tunnelled; bytes pass through untouched (TLS stays end to end).
final class E2ELiveRelay: @unchecked Sendable {
    let allowedHost: String
    private let queue = DispatchQueue(label: "e2e-live-relay")
    private var listener: NWListener?
    private var open: [ObjectIdentifier: [NWConnection]] = [:]
    private var downUntil = Date.distantPast
    private(set) var tunnels = 0, dropped = 0, refused = 0

    init(allowedHost: String) { self.allowedHost = allowedHost }

    /// Listens on 127.0.0.1 and returns the port, or nil when it cannot.
    func start() -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 5)
        return listener.port?.rawValue
    }

    func stop() { queue.sync { listener?.cancel(); open.values.flatMap { $0 }.forEach { $0.cancel() }; open = [:] } }

    /// The app's Hermes session: every request goes through this relay.
    func session(port: UInt16) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: Int(port),
            kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: Int(port),
        ]
        return URLSession(configuration: configuration)
    }

    /// Cuts every open tunnel now and refuses new ones for `seconds`.
    func drop(for seconds: TimeInterval) {
        queue.sync {
            downUntil = Date().addingTimeInterval(seconds)
            dropped += open.count
            open.values.flatMap { $0 }.forEach { $0.cancel() }; open = [:]
        }
    }

    var isDown: Bool { queue.sync { Date() < downUntil } }
    var counts: String { queue.sync { "tunnels=\(tunnels) dropped=\(dropped) refused=\(refused)" } }

    // MARK: Tunnels (on `queue`)

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var head = buffer; if let data { head.append(data) }
            guard error == nil, !complete || head.range(of: Data("\r\n\r\n".utf8)) != nil, head.count < 16_384 else { client.cancel(); return }
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else { readHead(client, buffer: head); return }
            let line = String(decoding: head.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
            guard line.count >= 2, line[0] == "CONNECT", line[1].lowercased() == "\(allowedHost):443" else {
                refused += 1; client.send(content: Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() }); return
            }
            // Down: the tunnel opens and closes at once, so the app sees the connection to the box drop (as offline, -1005),
            // never a failed proxy (CFNetwork 310), which URLSession then keeps refusing for a while.
            guard Date() >= downUntil else {
                refused += 1; client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() }); return
            }
            let upstream = NWConnection(host: .init(allowedHost), port: 443, using: .tcp)
            let key = ObjectIdentifier(client)
            open[key] = [client, upstream]
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    tunnels += 1
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                        self.pump(from: client, to: upstream, key: key); self.pump(from: upstream, to: client, key: key)
                    })
                case .failed, .cancelled: close(key)
                default: break
                }
            }
            upstream.start(queue: queue)
        }
    }

    private func pump(from source: NWConnection, to target: NWConnection, key: ObjectIdentifier) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                target.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { self.close(key) } else if !complete && error == nil { self.pump(from: source, to: target, key: key) }
                })
            }
            if complete || error != nil { close(key) } else if data?.isEmpty ?? true { pump(from: source, to: target, key: key) }
        }
    }

    private func close(_ key: ObjectIdentifier) {
        open.removeValue(forKey: key)?.forEach { $0.cancel() }
    }
}
