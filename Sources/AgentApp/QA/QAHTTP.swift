#if DEBUG
import Foundation
@preconcurrency import Network

enum QAHTTP {
    static let maximum = 2 * 1024 * 1024
    static let routes: Set<String> = ["attest", "begin", "action", "observe", "cleanup", "record", "checkpoint", "restart.prepare"]
    static func equal(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var different: UInt8 = 0
        for i in left.indices { different |= left[i] ^ right[i] }
        return different == 0
    }
    /// No chunking, pipelining, duplicate headers, origin requests, URL tokens, or browser preflight.
    static func parse(_ data: Data, port: UInt16, token: String) throws -> (String, ComposioValue)? {
        guard data.count <= maximum + 16_384 else { throw QAError.refused }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw QAError.refused }; return nil
        }
        guard end.upperBound <= 16_384, let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw QAError.refused }
        var lines = header.components(separatedBy: "\r\n")
        let first = lines.removeFirst().components(separatedBy: " ")
        guard first.count == 3, first[0] == "POST", first[2] == "HTTP/1.1", first[1].hasPrefix("/qa/v1/") else { throw QAError.refused }
        let route = String(first[1].dropFirst(7))
        guard routes.contains(route) else { throw QAError.refused }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw QAError.refused }
            let key = String(line[..<colon]).lowercased()
            guard key.range(of: #"\A[a-z0-9-]+\z"#, options: .regularExpression) != nil, headers[key] == nil else { throw QAError.refused }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw QAError.refused }
            headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil, headers["transfer-encoding"] == nil,
              headers["expect"] == nil, headers["content-type"] == "application/json",
              equal(headers["authorization"] ?? "", "Bearer " + token),
              let length = headers["content-length"], length.range(of: #"\A[0-9]{1,8}\z"#, options: .regularExpression) != nil,
              let size = Int(length), size > 0, size <= maximum else { throw QAError.refused }
        let available = data.count - end.upperBound
        guard available <= size else { throw QAError.refused }
        guard available == size else { return nil }
        let value = try JSONDecoder().decode(ComposioValue.self, from: data[end.upperBound...])
        guard value.object != nil else { throw QAError.refused }
        return (route, value)
    }
}

@MainActor final class QALocalServer {
    private let listener: NWListener
    private let token: String
    private let handler: @MainActor (String, ComposioValue) async throws -> ComposioValue
    private var connections: [UUID: NWConnection] = [:]
    private var requests = 0
    private var window = Date()
    init(token: String, handler: @escaping @MainActor (String, ComposioValue) async throws -> ComposioValue) throws {
        self.token = token; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping @MainActor (UInt16) throws -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .ready = state, let port = listener.port {
                    do { try ready(port.rawValue) } catch { stop() }
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
    }
    func stop() { listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll() }
    private func accept(_ connection: NWConnection) {
        if Date().timeIntervalSince(window) >= 60 { window = Date(); requests = 0 }
        requests += 1
        guard requests <= 600, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(8))
            connection?.cancel(); self?.connections[id] = nil
        }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer; if let data { buffer.append(data) }
                do {
                    guard let port = listener.port else { throw QAError.blocked }
                    if let (route, value) = try QAHTTP.parse(buffer, port: port.rawValue, token: token) {
                        Task { @MainActor in
                            do { respond(connection, id: id, status: 200, value: try await handler(route, value)) }
                            catch { respond(connection, id: id, status: 403, value: .object(["error": .string("QA operation blocked or refused")])) }
                        }
                    } else if complete || error != nil { connection.cancel(); connections[id] = nil }
                    else { receive(connection, id: id, buffer: buffer) }
                } catch { respond(connection, id: id, status: 403, value: .object(["error": .string("QA request refused")])) }
            }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, status: Int, value: ComposioValue) {
        guard let body = try? JSONEncoder().encode(value), body.count <= QAHTTP.maximum else { connection.cancel(); connections[id] = nil; return }
        var data = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Forbidden")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections[id] = nil }
        })
    }
}
#endif
