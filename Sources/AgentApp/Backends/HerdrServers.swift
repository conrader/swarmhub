import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One machine that runs Herdr Core and the SwarmHub bridge. The app keeps a list of them (`UserDefaults`, as JSON)
/// and each Herdr bot is bound to one. The access token is never part of this record: it lives in the Keychain.
/// Foundation only, like `HerdrClient`, so the list, its migration and the tunnel also build on Linux.
struct HerdrServer: Codable, Hashable, Identifiable, Sendable {
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

    /// Keep the typed endpoint in the saved record, including its SSH port for password and workspace identity.
    var sshEndpoint: SSHEndpoint? { SSHEndpoint(sshHost) }

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
    /// `.local` and `.ssh`: the port on the bridge’s machine.
    var port = String(HerdrServer.defaultPort)
    var sshDestination = "", sshKeyPath = ""
    /// The access token; empty reads it from the bridge's own file (this Mac, or the server over ssh).
    var key = ""

    init(kind: HerdrServer.Kind = .local) { self.kind = kind }
    init(server: HerdrServer) {
        kind = server.kind; name = server.name; address = server.address; port = String(server.port)
        sshDestination = server.sshUser.isEmpty ? server.sshHost : "\(server.sshUser)@\(server.sshHost)"
        sshKeyPath = server.sshKeyPath
    }

    var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }

    /// Accept the usual Terminal spelling when pasted, but only extract a single SSH destination.
    private var sshLogin: (host: String, user: String)? {
        var target = sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasPrefix("ssh ") { target = String(target.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        let parts = target.components(separatedBy: "@")
        guard parts.count <= 2, let host = parts.last, SSHEndpoint(host) != nil else { return nil }
        if parts.count == 1 { return (host, "") }
        let user = parts[0]
        guard !user.isEmpty, HerdrTunnel.isSafe(user: user) else { return nil }
        return (host, user)
    }

    /// One plain line for the first thing that is missing or wrong; nil when Test can run.
    var problem: String? {
        switch kind {
        case .local: return portNumber == nil ? "The port is a number from 1 to 65535. It is 8787 unless you changed it." : nil
        case .ssh:
            guard sshLogin != nil else { return "Enter a server name, IP address, or user@server." }
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
            guard let login = sshLogin else { return nil }
            return HerdrServer(id: id, name: typed.isEmpty ? login.host : typed, kind: .ssh, address: HerdrServer.loopback(port: portNumber ?? HerdrServer.defaultPort),
                               sshHost: login.host, sshUser: login.user, sshKeyPath: sshKeyPath.trimmingCharacters(in: .whitespaces))
        case .address:
            guard let url = HerdrClient.validatedBaseURL(address) else { return nil }
            return HerdrServer(id: id, name: typed.isEmpty ? (url.host ?? "Herdr") : typed, kind: .address, address: url.absoluteString)
        }
    }
}

/// The SSH endpoint and the workspace's HTTP port are independent. Bare IPv6 addresses have no port suffix.
struct SSHEndpoint {
    let host: String
    let port: UInt16?

    init?(_ text: String) {
        guard HerdrTunnel.isSafe(host: text) else { return nil }
        let suffix: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let enclosed = text[text.index(after: text.startIndex)..<close]
            guard enclosed.contains(":"), !enclosed.contains("[") else { return nil }
            host = String(enclosed)
            suffix = text.suffix(from: text.index(after: close))
        } else {
            guard !text.contains("["), !text.contains("]") else { return nil }
            if let colon = text.firstIndex(of: ":"), colon == text.lastIndex(of: ":") {
                host = String(text[..<colon])
                suffix = text[colon...]
            } else {
                host = text
                suffix = ""
            }
        }
        guard HerdrTunnel.isSafe(host: host) else { return nil }
        if suffix.isEmpty {
            port = nil
        } else {
            let digits = suffix.dropFirst()
            guard suffix.first == ":", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt16(digits), number > 0 else { return nil }
            port = number
        }
    }
}

/// The port forward to an `.ssh` server: `ssh -N -L 127.0.0.1:<port>:127.0.0.1:<port>`, a child process of the app.
/// ssh is the system's own, so the person's `~/.ssh/config`, agent and known hosts all apply; the app adds nothing
/// to them and never reads a key. Batch mode: a key that needs a passphrase must already be in the agent, because a
/// background process has nowhere to ask for one.
enum HerdrTunnel {
    static let program = "/usr/bin/ssh"
    static let forwardReady = "SWARMHUB_SSH_FORWARD_READY"
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
        guard server.kind == .ssh, let endpoint = server.sshEndpoint, isSafe(user: server.sshUser) else { return nil }
        var arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15",
                         "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if let port = endpoint.port { arguments += ["-p", String(port)] }
        if !server.sshKeyPath.isEmpty {
            let path = server.sshKeyPath.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(server.sshKeyPath.dropFirst(2))) : server.sshKeyPath
            arguments += ["-i", path, "-o", "IdentitiesOnly=yes"]
        }
        if !server.sshUser.isEmpty { arguments += ["-l", server.sshUser] }
        return arguments
    }

    /// `ssh -N -L …` binds to loopback here and exits when it cannot bind the requested port.
    static func forwardArguments(for server: HerdrServer, localPort: Int? = nil, home: String = HerdrTunnel.realHome) -> [String]? {
        guard let endpoint = server.sshEndpoint, let options = options(for: server, home: home) else { return nil }
        let port = server.port
        // Keep the listener on this process, and get an acknowledgement from ssh after it binds the port.
        return ["-N", "-L", "127.0.0.1:\(localPort ?? port):127.0.0.1:\(port)", "-o", "ExitOnForwardFailure=yes",
                "-S", "none", "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=/bin/echo \(forwardReady)"]
            + options + ["--", endpoint.host]
    }

    /// One command on the server (reading the bridge's token file), its output trimmed.
    static func commandArguments(for server: HerdrServer, command: String, home: String = HerdrTunnel.realHome) -> [String]? {
        guard let endpoint = server.sshEndpoint, let options = options(for: server, home: home) else { return nil }
        return options + ["--", endpoint.host, command]
    }

    /// The last line ssh wrote before it gave up, without the "Warning: Permanently added" notice.
    static func reason(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? "ssh ended without saying why."
    }

    static func cannotBind(_ port: Int, stderr: String) -> Bool {
        let message = "cannot listen to port: \(port)"
        return stderr.split(whereSeparator: \.isNewline).contains { $0 == message || $0.hasSuffix(": " + message) }
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

    /// Only OpenSSH authentication failures that permit a password should open the sign-in form.
    static func offersPassword(_ error: Error) -> Bool {
        guard case .ended(let line) = error as? Failure,
              let methods = line.range(of: #"Permission denied \(([a-zA-Z0-9@.,_-]+)\)\.?$"#, options: .regularExpression) else { return false }
        let offered = line[methods].split(whereSeparator: { "(),. ".contains($0) })
        return offered.contains("password") || offered.contains("keyboard-interactive")
    }

    /// Runs a setup command on the server. A file on stdin can carry a verified service binary.
    static func run(_ command: String, on server: HerdrServer, password: String? = nil, timeout: Duration = .seconds(30),
                    standardInput: FileHandle = .nullDevice) async throws -> String {
        guard let arguments = commandArguments(for: server, command: command) else { throw Failure.notSSH }
        final class Running: @unchecked Sendable { let process = Process() }
        let running = Running(), out = Pipe(), err = Pipe()
        running.process.executableURL = URL(fileURLWithPath: program); running.process.arguments = arguments
        let input = try password.map(SSHPasswordInput.init(password:))
        input?.configure(running.process, arguments: arguments)
        defer { withExtendedLifetime(input) {} }
        running.process.standardInput = standardInput; running.process.standardOutput = out; running.process.standardError = err
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
    struct PortBindFailure: Error { let line: String }

    /// What ssh last wrote, kept short.
    private final class Tail: @unchecked Sendable {
        private let lock = NSLock(); private var text = ""
        func add(_ data: Data) {
            lock.withLock { text = String((text + String(decoding: data, as: UTF8.self)).suffix(2_000)) }
        }
        func watch(_ pipe: Pipe) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { self.add(data) }
            }
        }
        var value: String { lock.withLock { text } }
    }
    private struct Entry { var process: Process; var arguments: [String]; var ready: Bool }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// One opening at a time per server: several requests may ask at once.
    private var opening: [String: Task<Int, Error>] = [:]
    private let isPortFree: @Sendable (Int) -> Bool

    init(isPortFree: @escaping @Sendable (Int) -> Bool = HerdrTunnels.isFree) {
        self.isPortFree = isPortFree
    }
    private struct Login: Hashable {
        let host: String
        let user: String
        init(_ server: HerdrServer) { host = server.sshHost; user = server.sshUser }
    }
    private var passwords: [Login: String] = [:]

    func password(for server: HerdrServer) -> String? { lock.withLock { passwords[Login(server)] } }

    func forgetPassword(for server: HerdrServer) { lock.withLock { passwords[Login(server)] = nil } }

    func signIn(to server: HerdrServer, password: String) async throws {
        _ = try await HerdrTunnel.run("true", on: server, password: password)
        try Task.checkCancellation()
        lock.withLock { passwords[Login(server)] = password }
    }

    private func discardRejected(_ attempted: String?, for server: HerdrServer, error: Error) {
        guard let attempted, HerdrTunnel.offersPassword(error) else { return }
        lock.withLock {
            if passwords[Login(server)] == attempted { passwords[Login(server)] = nil }
        }
    }

    func readToken(on server: HerdrServer) async throws -> String {
        let attempted = password(for: server)
        do { return try await HerdrTunnel.run(HerdrServerList.remoteTokenCommand, on: server, password: attempted) }
        catch { discardRejected(attempted, for: server, error: error); throw error }
    }

    private var forwardPorts: [String: Int] = [:]

    /// Each SSH server gets its own local listener, including when several bridges use 8787.
    func forwardPort(for server: HerdrServer, avoiding configuredPorts: Set<Int>) throws -> Int {
        try lock.withLock {
            try forwardPorts[server.id] ?? pickPort(for: server, avoiding: configuredPorts)
        }
    }

    // Call while holding the lock. SSH claims the actual listener, so a retry must probe a different port.
    private func pickPort(for server: HerdrServer, avoiding configuredPorts: Set<Int>, replacing failedPort: Int? = nil) throws -> Int {
        let used = configuredPorts.union(forwardPorts.values)
        let candidates = (49152...65535).lazy.filter { $0 != failedPort && !used.contains($0) }
        let preferred = server.port != failedPort && !used.contains(server.port) ? server.port : nil
        let port = preferred.flatMap { isPortFree($0) ? $0 : nil }
            ?? (failedPort == nil ? candidates.prefix(20).first(where: isPortFree) : candidates.first(where: isPortFree))
            ?? (failedPort == nil ? preferred ?? candidates.first : nil)
        guard let port else { throw HerdrTunnel.Failure.ended("No local port is available for the SSH connection.") }
        forwardPorts[server.id] = port
        return port
    }

    /// True while this server's forward is the app's own running ssh.
    func isOpen(_ id: String) -> Bool { lock.withLock { entries[id].map { $0.process.isRunning && $0.ready } ?? false } }

    func ensure(_ server: HerdrServer, avoiding configuredPorts: Set<Int>) async throws -> Int {
        let port = try forwardPort(for: server, avoiding: configuredPorts)
        guard let arguments = HerdrTunnel.forwardArguments(for: server, localPort: port) else { throw HerdrTunnel.Failure.notSSH }
        let pending: Task<Int, Error>? = lock.withLock {
            if let running = opening[server.id] { return running }
            if let entry = entries[server.id], forwardPorts[server.id] == port,
               entry.process.isRunning, entry.ready, entry.arguments == arguments { return nil }
            let task = Task {
                try await self.startForward(server, avoiding: configuredPorts) { port, arguments in
                    try await self.open(server, port: port, arguments: arguments)
                }
            }
            opening[server.id] = task
            return task
        }
        guard let pending else { return port }
        defer { lock.withLock { if opening[server.id] == pending { opening[server.id] = nil } } }
        return try await pending.value
    }

    func startForward(_ server: HerdrServer, avoiding configuredPorts: Set<Int>,
                      open: (Int, [String]) async throws -> Void) async throws -> Int {
        func openPort(_ port: Int) async throws {
            guard let arguments = HerdrTunnel.forwardArguments(for: server, localPort: port) else { throw HerdrTunnel.Failure.notSSH }
            try await open(port, arguments)
        }
        let port = try forwardPort(for: server, avoiding: configuredPorts)
        do {
            try await openPort(port)
            return port
        } catch is PortBindFailure {
            let replacement = try lock.withLock {
                forwardPorts[server.id] = nil
                return try pickPort(for: server, avoiding: configuredPorts, replacing: port)
            }
            do {
                try await openPort(replacement)
                return replacement
            } catch let failure as PortBindFailure {
                lock.withLock { if forwardPorts[server.id] == replacement { forwardPorts[server.id] = nil } }
                throw HerdrTunnel.Failure.ended(failure.line)
            }
        }
    }

    /// Ends the forward. ssh holds nothing worth a clean exit, and a child started from a thread that blocks signals
    /// would never see a polite one, so it is killed outright.
    func close(_ id: String) {
        let entry = lock.withLock { entries.removeValue(forKey: id) }
        if let entry, entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
    }

    func release(_ id: String) {
        close(id)
        lock.withLock { forwardPorts[id] = nil }
    }

    func closeAll() {
        lock.withLock { passwords.removeAll() }
        for id in lock.withLock({ Array(entries.keys) }) { close(id) }
    }

    private func open(_ server: HerdrServer, port: Int, arguments: [String]) async throws {
        close(server.id)
        let process = Process(), out = Pipe(), err = Pipe(), status = Tail(), tail = Tail()
        process.executableURL = URL(fileURLWithPath: HerdrTunnel.program); process.arguments = arguments
        let attempted = password(for: server)
        let input = try attempted.map(SSHPasswordInput.init(password:))
        input?.configure(process, arguments: arguments)
        defer { withExtendedLifetime(input) {} }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        status.watch(out)
        tail.watch(err)
        do { try process.run() } catch { throw HerdrTunnel.Failure.ended(error.localizedDescription) }
        lock.withLock { entries[server.id] = Entry(process: process, arguments: arguments, ready: false) }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(25)
        while clock.now < deadline {
            if !process.isRunning {
                lock.withLock { if entries[server.id]?.process === process { entries[server.id] = nil } }
                try? await Task.sleep(for: .milliseconds(100)) // the last line may still be on its way through the pipe
                let stderr = tail.value
                let line = HerdrTunnel.reason(stderr)
                if HerdrTunnel.cannotBind(port, stderr: stderr) { throw PortBindFailure(line: line) }
                let error = HerdrTunnel.Failure.ended(line)
                discardRejected(attempted, for: server, error: error)
                throw error
            }
            if status.value.split(whereSeparator: \.isNewline).contains(where: { $0 == HerdrTunnel.forwardReady }),
               await Self.answers(port: port), process.isRunning {
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
