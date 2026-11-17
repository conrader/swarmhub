import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One machine that runs Herdr Core and the SwarmHub bridge. The app keeps a list of them (`UserDefaults`, as JSON)
/// and each Herdr bot is bound to one. The access token is never part of this record: it lives in the Keychain.
/// Foundation only, like `HerdrClient`, so the list, its migration and the tunnel also build on Linux.
struct HerdrServer: Codable, Equatable, Identifiable, Sendable {
    /// How the app reaches the bridge. The bridge answers on its own machine's loopback only, so `ssh` is that same
    /// loopback port carried here by a forward the app opens itself, and `address` is a forward someone else opened.
    enum Kind: String, Codable, CaseIterable, Sendable { case local, ssh, address }

    var id: String
    var name: String
    var kind: Kind
    /// `.address`: what the person typed. `.local` and `.ssh`: always `http://127.0.0.1:<port>`.
    var address: String
    /// `.ssh` only: the machine to log in to, the login name (empty: ssh's own configuration decides) and the path
    /// of a private key file (empty: ssh's own keys and agent). Only the path is kept, never the key.
    var sshHost = "", sshUser = "", sshKeyPath = ""

    /// The server an install had before there was a list; it keeps Keychain account `herdr` and the environment token.
    static let defaultID = "default"
    static let listKey = "herdrServers", defaultPort = 8787
    static func botKey(_ botID: UUID) -> String { "herdrServer.\(botID.uuidString.lowercased())" }

    /// Keychain account of this server's access token.
    var keyAccount: String { id == Self.defaultID ? HerdrServerList.legacyKeyAccount : "\(HerdrServerList.legacyKeyAccount).\(id)" }
    var port: Int { HerdrClient.validatedBaseURL(address)?.port ?? Self.defaultPort }
    static func loopback(port: Int) -> String { "http://127.0.0.1:\(port)" }

    /// "This Mac", "deploy@studio.example.com" or the typed address: where it is, under the name.
    var place: String {
        switch kind {
        case .local: port == Self.defaultPort ? "This Mac" : "This Mac, port \(port)"
        case .ssh: (sshUser.isEmpty ? "" : "\(sshUser)@") + sshHost + (port == Self.defaultPort ? "" : ", port \(port)")
        case .address: address
        }
    }

    enum CodingKeys: CodingKey { case id, name, kind, address, sshHost, sshUser, sshKeyPath }
    init(id: String, name: String, kind: Kind, address: String, sshHost: String = "", sshUser: String = "", sshKeyPath: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.sshHost = sshHost; self.sshUser = sshUser; self.sshKeyPath = sshKeyPath
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        // A kind written by a newer build reads as a plain address rather than losing the whole list.
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .address
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost) ?? ""; sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? ""
    }
}

/// The saved list and what stands in for it before one is saved.
enum HerdrServerList {
    /// `UserDefaults` key of the single bridge address an install had before the list, and its Keychain account.
    static let legacyAddressKey = "herdrBaseURL", legacyKeyAccount = "herdr"

    /// The saved servers. With none saved there is still one: the address this install used before the list (so its
    /// bots keep working without a visible migration), or this Mac's own bridge on a fresh install.
    static func servers(json: String?, legacyAddress: String?) -> [HerdrServer] {
        if let data = json?.data(using: .utf8), let saved = try? JSONDecoder().decode([HerdrServer].self, from: data), !saved.isEmpty { return saved }
        if let legacyAddress, !legacyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [HerdrServer(id: HerdrServer.defaultID, name: "Herdr", kind: .address, address: legacyAddress)]
        }
        return [HerdrServer(id: HerdrServer.defaultID, name: "This Mac", kind: .local, address: HerdrServer.loopback(port: HerdrServer.defaultPort))]
    }

    static func json(_ servers: [HerdrServer]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(servers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The server a bot is bound to: its saved choice while that server exists, otherwise the first one.
    static func server(bound id: String?, in servers: [HerdrServer]) -> HerdrServer? { servers.first { $0.id == id } ?? servers.first }

    /// A short id for a new server; it becomes part of a Keychain account name and a `UserDefaults` value.
    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) }

    /// Where the bridge's own start script keeps its token (`HerdrWorkspace/dev/start-local.sh`), under a home folder.
    static let tokenFile = ".config/swarmhub-herdr/token"
    /// The same file as a remote shell finds it.
    static let remoteTokenCommand = "cat \"${XDG_CONFIG_HOME:-$HOME/.config}/swarmhub-herdr/token\""

    /// This machine's bridge token, read from the file its start script wrote, when the bridge runs here.
    static func localToken(homes: [String]) -> String {
        for home in homes {
            let path = (home as NSString).appendingPathComponent(tokenFile)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }
        }
        return ""
    }
}

/// What the setup window and Settings collect for one server before anything is saved.
struct HerdrServerDraft: Equatable, Sendable {
    var kind = HerdrServer.Kind.local
    var name = ""
    /// `.address` only.
    var address = ""
    /// `.local` and `.ssh`: the bridge's port, the same on both ends of the forward because the bridge checks it.
    var port = String(HerdrServer.defaultPort)
    var sshHost = "", sshUser = "", sshKeyPath = ""
    /// The access token; empty reads it from the bridge's own file (this Mac, or the server over ssh).
    var key = ""

    init(kind: HerdrServer.Kind = .local) { self.kind = kind }
    init(server: HerdrServer) {
        kind = server.kind; name = server.name; address = server.address; port = String(server.port)
        sshHost = server.sshHost; sshUser = server.sshUser; sshKeyPath = server.sshKeyPath
    }

    var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }

    /// One plain line for the first thing that is missing or wrong; nil when Test can run.
    var problem: String? {
        switch kind {
        case .local: return portNumber == nil ? "The port is a number from 1 to 65535. It is 8787 unless you changed it." : nil
        case .ssh:
            if sshHost.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the server's name or IP address." }
            if !HerdrTunnel.isSafe(host: sshHost.trimmingCharacters(in: .whitespaces)) || !HerdrTunnel.isSafe(user: sshUser.trimmingCharacters(in: .whitespaces)) {
                return "Use only the server's name or IP address, and a plain login name."
            }
            return portNumber == nil ? "The port is a number from 1 to 65535. It is 8787 unless you changed it." : nil
        case .address:
            if address.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the address, for example http://127.0.0.1:8787." }
            return HerdrClient.validatedBaseURL(address) == nil ? HerdrClient.Failure.invalidURL.errorDescription : nil
        }
    }

    /// The record this draft saves as; nil while `problem` is set.
    func server(id: String) -> HerdrServer? {
        guard problem == nil else { return nil }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .local:
            return HerdrServer(id: id, name: typed.isEmpty ? "This Mac" : typed, kind: .local, address: HerdrServer.loopback(port: portNumber ?? HerdrServer.defaultPort))
        case .ssh:
            let host = sshHost.trimmingCharacters(in: .whitespaces)
            return HerdrServer(id: id, name: typed.isEmpty ? host : typed, kind: .ssh, address: HerdrServer.loopback(port: portNumber ?? HerdrServer.defaultPort),
                               sshHost: host, sshUser: sshUser.trimmingCharacters(in: .whitespaces), sshKeyPath: sshKeyPath.trimmingCharacters(in: .whitespaces))
        case .address:
            guard let url = HerdrClient.validatedBaseURL(address) else { return nil }
            return HerdrServer(id: id, name: typed.isEmpty ? (url.host ?? "Herdr") : typed, kind: .address, address: url.absoluteString)
        }
    }
}

/// The port forward to an `.ssh` server: `ssh -N -L 127.0.0.1:<port>:127.0.0.1:<port>`, a child process of the app.
/// ssh is the system's own, so the person's `~/.ssh/config`, agent and known hosts all apply; the app adds nothing
/// to them and never reads a key. Batch mode: a key that needs a passphrase must already be in the agent, because a
/// background process has nowhere to ask for one.
enum HerdrTunnel {
    static let program = "/usr/bin/ssh"
    /// The person's own home folder, where ssh itself looks, whatever folder a development launch calls home.
    static var realHome: String { getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory() }

    /// A host or login that cannot be mistaken for an ssh option or carry a second argument.
    static func isSafe(host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_:[]%".unicodeScalars.contains($0)) }
    }
    static func isSafe(user: String) -> Bool {
        user.isEmpty || (!user.hasPrefix("-") && user.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)) })
    }

    /// The options every ssh call of the app shares. A server seen for the first time is trusted once and remembered
    /// (as answering "yes" would); a server whose key later changes is refused.
    static func options(for server: HerdrServer, home: String = HerdrTunnel.realHome) -> [String]? {
        guard server.kind == .ssh, isSafe(host: server.sshHost), isSafe(user: server.sshUser) else { return nil }
        var arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
                         "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if !server.sshKeyPath.isEmpty {
            let path = server.sshKeyPath.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(server.sshKeyPath.dropFirst(2))) : server.sshKeyPath
            arguments += ["-i", path, "-o", "IdentitiesOnly=yes"]
        }
        if !server.sshUser.isEmpty { arguments += ["-l", server.sshUser] }
        return arguments
    }

    /// `ssh -N -L …`: the same port on both ends, bound to loopback here, and ssh exits when it cannot bind it.
    static func forwardArguments(for server: HerdrServer, localPort: Int? = nil, home: String = HerdrTunnel.realHome) -> [String]? {
        guard let options = options(for: server, home: home) else { return nil }
        let port = server.port
        return ["-N", "-L", "127.0.0.1:\(localPort ?? port):127.0.0.1:\(port)", "-o", "ExitOnForwardFailure=yes"] + options + ["--", server.sshHost]
    }

    /// One command on the server (reading the bridge's token file), its output trimmed.
    static func commandArguments(for server: HerdrServer, command: String, home: String = HerdrTunnel.realHome) -> [String]? {
        options(for: server, home: home).map { $0 + ["--", server.sshHost, command] }
    }

    /// The last line ssh wrote before it gave up, without the "Warning: Permanently added" notice.
    static func reason(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? "ssh ended without saying why."
    }

    enum Failure: LocalizedError, Equatable {
        case notSSH, ended(String), timedOut
        var errorDescription: String? {
            switch self {
            case .notSSH: "This server is not reached over SSH."
            case .ended(let line): "The SSH connection did not open: \(line)"
            case .timedOut: "The SSH connection did not open in time."
            }
        }
    }

    /// Runs `command` on the server and returns what it printed. Used once, to read the access token.
    static func run(_ command: String, on server: HerdrServer, timeout: Duration = .seconds(30)) async throws -> String {
        guard let arguments = commandArguments(for: server, command: command) else { throw Failure.notSSH }
        final class Running: @unchecked Sendable { let process = Process() }
        let running = Running(), out = Pipe(), err = Pipe()
        running.process.executableURL = URL(fileURLWithPath: program); running.process.arguments = arguments
        running.process.standardInput = FileHandle.nullDevice; running.process.standardOutput = out; running.process.standardError = err
        let limit = Task { try await Task.sleep(for: timeout); if running.process.isRunning { kill(running.process.processIdentifier, SIGKILL) } }
        defer { limit.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            running.process.terminationHandler = { finished in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let problem = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 { continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { continuation.resume(throwing: Failure.ended(reason(problem))) }
            }
            do { try running.process.run() } catch { running.process.terminationHandler = nil; continuation.resume(throwing: Failure.ended(error.localizedDescription)) }
        }
    }
}

/// The app's open forwards, one per `.ssh` server. `ensure` is called before every request to such a server
/// (`HerdrClient.prepare`): it returns at once while the forward is up, and opens it again when ssh has ended (the
/// Mac slept, the network changed). Nothing here is saved; closing the app closes its forwards.
final class HerdrTunnels: @unchecked Sendable {
    /// What ssh last wrote, kept short; read when it ends before the forward opened.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock(); private var text = ""
        func add(_ data: Data) { lock.withLock { text = String((text + (String(data: data, encoding: .utf8) ?? "")).suffix(2_000)) } }
        var value: String { lock.withLock { text } }
    }
    private struct Entry { var process: Process; var arguments: [String]; var ready: Bool }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// One opening at a time per server: several requests may ask at once.
    private var opening: [String: Task<Void, Error>] = [:]
    /// Checks forward to another local port; the app always uses the server's own.
    var localPort: (@Sendable (HerdrServer) -> Int?)?

    /// True while this server's forward is the app's own running ssh.
    func isOpen(_ id: String) -> Bool { lock.withLock { entries[id].map { $0.process.isRunning && $0.ready } ?? false } }

    func ensure(_ server: HerdrServer) async throws {
        guard let arguments = HerdrTunnel.forwardArguments(for: server, localPort: localPort?(server)) else { throw HerdrTunnel.Failure.notSSH }
        let pending: Task<Void, Error>? = lock.withLock {
            if let entry = entries[server.id], entry.process.isRunning, entry.ready, entry.arguments == arguments { return nil }
            if let running = opening[server.id] { return running }
            let task = Task { try await self.open(server, arguments: arguments) }
            opening[server.id] = task
            return task
        }
        guard let pending else { return }
        defer { lock.withLock { if opening[server.id] == pending { opening[server.id] = nil } } }
        try await pending.value
    }

    /// Ends the forward. ssh holds nothing worth a clean exit, and a child started from a thread that blocks signals
    /// would never see a polite one, so it is killed outright.
    func close(_ id: String) {
        let entry = lock.withLock { entries.removeValue(forKey: id) }
        if let entry, entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
    }

    func closeAll() { for id in lock.withLock({ Array(entries.keys) }) { close(id) } }

    private func open(_ server: HerdrServer, arguments: [String]) async throws {
        close(server.id)
        let port = localPort?(server) ?? server.port
        // A forward left by an earlier run of the app (or one the person opened) already carries the port: use it.
        if await Self.answers(port: port) { return }
        let process = Process(), err = Pipe(), tail = Tail()
        process.executableURL = URL(fileURLWithPath: HerdrTunnel.program); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = err
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.add(data) }
        }
        do { try process.run() } catch { throw HerdrTunnel.Failure.ended(error.localizedDescription) }
        lock.withLock { entries[server.id] = Entry(process: process, arguments: arguments, ready: false) }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(25)
        while clock.now < deadline {
            if !process.isRunning {
                lock.withLock { if entries[server.id]?.process === process { entries[server.id] = nil } }
                try? await Task.sleep(for: .milliseconds(100)) // the last line may still be on its way through the pipe
                throw HerdrTunnel.Failure.ended(HerdrTunnel.reason(tail.value))
            }
            if await Self.answers(port: port) {
                lock.withLock { if entries[server.id]?.process === process { entries[server.id]?.ready = true } }
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        close(server.id)
        throw HerdrTunnel.Failure.timedOut
    }

    /// Whether no program on this machine listens on the loopback port, found the way the service finds it: by binding it.
    nonisolated static func isFree(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { Darwin.close(handle) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    /// The first port after `port` that no program listens on, within the next twenty.
    nonisolated static func freePort(after port: Int, isFree: (Int) -> Bool = HerdrTunnels.isFree) -> Int? {
        (port + 1...port + 20).first { $0 <= 65535 && isFree($0) }
    }

    /// Whether anything speaks HTTP on this machine's loopback port (the bridge's own page needs no token).
    static func answers(port: Int) async -> Bool {
        guard let url = URL(string: "\(HerdrServer.loopback(port: port))/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3); request.httpMethod = "GET"
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}
