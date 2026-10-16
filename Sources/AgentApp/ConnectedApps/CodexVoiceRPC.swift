import Foundation

enum CodexVoiceError: LocalizedError, Equatable {
    case missingCodex, disconnected, timedOut, invalidResponse, signInRequired, unavailable, audioUnavailable
    var errorDescription: String? {
        switch self {
        case .missingCodex: "Install or update the ChatGPT desktop app or Codex CLI, then reconnect. You can also choose a Codex executable under Connected apps → ChatGPT → Connection options."
        case .disconnected: "The Codex voice connection closed. Reconnect to try again."
        case .timedOut: "Codex did not respond in time. Check your connection and try again."
        case .invalidResponse: "This Codex build returned an unsupported voice response. Update ChatGPT or Codex and reconnect."
        case .signInRequired: "Sign in with ChatGPT to use your subscription for voice."
        case .unavailable: "Codex could not open live voice for this account. Check your plan, workspace permissions and voice availability, and update ChatGPT or Codex."
        case .audioUnavailable: "Could not start voice audio. Check your microphone and output device, then try again."
        }
    }
}

/// P55: a JSON-RPC error from the app-server, with its code and message. The message is the provider's own text and can
/// carry headers or tokens: it reaches the screen, the clipboard and the log only through `VoiceRedaction`, and this
/// error's own description is the fixed line of `fallback`.
struct CodexRPCError: LocalizedError, Equatable {
    let code: Int64
    let message: String
    var fallback: CodexVoiceError { code == -32601 || code == -32602 ? .invalidResponse : .unavailable }
    var errorDescription: String? { fallback.errorDescription }
}

@MainActor protocol CodexVoiceConnection: AnyObject {
    var onNotification: ((String, JSONValue) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func connect() async throws
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue
    func close(stopping threadID: String?)
}

/// A private app-server process (`codex app-server`, JSON-RPC lines over stdio). Codex owns OAuth and token renewal;
/// SwarmHub never reads its tokens. P38 B uses it for the ChatGPT connection; the voice window (part C) builds on it.
@MainActor final class CodexVoiceRPC: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    private let executable: URL
    private let home: URL
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var nextID: Int64 = 0
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
    }
    private var pending: [Int64: Pending] = [:]
    /// The request timers' clock (injected by tests, like `ChatGPTConnection`'s).
    private let sleep: @Sendable (Duration) async throws -> Void

    init(executable: URL? = nil, home: URL? = nil, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        guard let executable = executable ?? Self.findExecutable() else { throw CodexVoiceError.missingCodex }
        self.executable = executable; self.sleep = sleep
        self.home = home ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SwarmHub/CodexVoice", directoryHint: .isDirectory)
    }

    static func findExecutable() -> URL? {
        let configured = UserDefaults.standard.string(forKey: "codexVoiceExecutable") ?? ""
        if !configured.isEmpty {
            let url = URL(fileURLWithPath: configured).resolvingSymlinksInPath()
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return URL(fileURLWithPath: configured)
        }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.first { !$0.isEmpty && $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func connect() async throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        proc.executableURL = executable
        // This window provides conversation. Agent actions still go through SwarmHub's normal chats.
        proc.arguments = ["app-server", "--disable", "shell_tool", "--disable", "unified_exec",
                          "--disable", "apps", "--disable", "plugins", "--disable", "multi_agent"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        // An inherited Platform key must never change this subscription-only connection into API billing.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        proc.environment = environment; proc.currentDirectoryURL = home
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc; input = stdin.fileHandleForWriting
        reader = Task { [weak self] in
            do {
                // Read ordered byte chunks without an unbounded line buffer.
                var frame = Data()
                for try await byte in stdout.fileHandleForReading.bytes {
                    try Task.checkCancellation()
                    if byte == 10 {
                        guard let value = try? GrokJSON.parse(frame) else { throw CodexVoiceError.invalidResponse }
                        self?.receive(value); frame.removeAll(keepingCapacity: true)
                    } else {
                        guard frame.count < 8_388_608 else { throw CodexVoiceError.invalidResponse }
                        frame.append(byte)
                    }
                }
            } catch { /* Closing a process cancels this read as well. */ }
            self?.didClose()
        }
        do {
            _ = try await request("initialize", params: [
                "clientInfo": .object(["name": .string("swarmhub_voice"), "title": .string("SwarmHub Voice"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ], timeout: .seconds(15))
            try write(.object(["method": .string("initialized"), "params": .object([:])]))
        } catch { close(stopping: nil); throw error }
    }

    func request(_ method: String, params: [String: JSONValue] = [:], timeout: Duration = .seconds(15)) async throws -> JSONValue {
        try Task.checkCancellation()
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, sleep] in
                    do { try await sleep(timeout) } catch { return }
                    self?.complete(id, with: .failure(CodexVoiceError.timedOut))
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                do { try write(.object(["id": .int(id), "method": .string(method), "params": .object(params)])) }
                catch { complete(id, with: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, with: .failure(CancellationError())) }
        }
    }

    private func write(_ value: JSONValue) throws {
        guard let input, process?.isRunning == true else { throw CodexVoiceError.disconnected }
        var data = try JSONEncoder().encode(value); data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ message: JSONValue) {
        if let method = message["method"]?.stringValue {
            if let id = message["id"] {
                // No server-initiated tool or approval flow is implemented in a voice conversation.
                try? write(.object(["id": id, "error": .object(["code": .int(-32601), "message": .string("This client supports voice conversation only.")])]))
            } else { onNotification?(method, message["params"] ?? .object([:])) }
        } else if let id = message["id"]?.intValue {
            if let result = message["result"] { complete(id, with: .success(result)) }
            else {
                let error = message["error"]
                complete(id, with: .failure(CodexRPCError(code: error?["code"]?.intValue ?? 0,
                                                          message: String((error?["message"]?.stringValue ?? "").prefix(4_000)))))
            }
        }
    }

    private func complete(_ id: Int64, with result: Result<JSONValue, Error>) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timer.cancel(); waiting.continuation.resume(with: result)
    }

    func close(stopping threadID: String? = nil) {
        onClose = nil; onNotification = nil
        if let threadID {
            nextID += 1
            try? write(.object(["id": .int(nextID), "method": .string("thread/realtime/stop"), "params": .object(["threadId": .string(threadID)])]))
        }
        let proc = process; process = nil
        try? input?.close(); input = nil
        reader?.cancel(); reader = nil
        for id in Array(pending.keys) { complete(id, with: .failure(CodexVoiceError.disconnected)) }
        // Give stop/EOF a chance to close the upstream voice session before terminating a hung child.
        Task { try? await Task.sleep(for: .seconds(1)); if proc?.isRunning == true { proc?.terminate() } }
    }

    private func didClose() {
        guard process != nil else { return }
        let callback = onClose
        close(); callback?()
    }
}
