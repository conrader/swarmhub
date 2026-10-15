import AppKit
import Combine
import Foundation

/// P38 B: ChatGPT as a native connected app, independent of Composio: a private Codex app-server (`CodexVoiceRPC`)
/// with its own `CODEX_HOME` signs in with the user's ChatGPT account (Codex manages the OAuth credentials; SwarmHub
/// never reads them) and checks whether live voice works through the subscription. The sign-in page opens through
/// `ExternalLink`; the waits are injected for tests.
@MainActor final class ChatGPTConnection: ObservableObject {
    static let shared = ChatGPTConnection()
    enum State: Equatable { case idle, checking, signedOut, signingIn, connected, disconnecting }
    enum VoiceAccess: Equatable { case unknown, checking, available, requiresAPIKey, unavailable }
    @Published private(set) var state: State = .idle
    @Published private(set) var voiceAccess: VoiceAccess = .unknown
    @Published private(set) var plan: String?
    @Published private(set) var email: String?
    @Published private(set) var errorMessage: String?
    var isConnected: Bool { state == .connected }
    var canUseVoice: Bool { isConnected && voiceAccess == .available }
    var voiceAccessMessage: String {
        switch voiceAccess {
        case .unknown: "Connect ChatGPT to check subscription voice access."
        case .checking: "Checking subscription voice access…"
        case .available: "Voice enabled"
        case .requiresAPIKey: "This Codex build requires an API key for live voice. ChatGPT subscription voice is unavailable through this connection."
        case .unavailable: "Live voice is unavailable through this connection. Update ChatGPT or Codex and check your account's voice access."
        }
    }
    var isBusy: Bool { [.checking, .signingIn, .disconnecting].contains(state) }
    var onVoiceNotification: ((String, JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    private var client: (any CodexVoiceConnection)?
    private var operation: Task<Void, Never>?
    private var loginTimer: Task<Void, Never>?
    private var loginID: String?
    private var probeThreadID: String?
    private var probeEvents: AsyncStream<VoiceAccess>.Continuation?
    private var generation = UUID()
    private let makeClient: () throws -> any CodexVoiceConnection
    private let openURL: (URL) -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void

    init(makeClient: @escaping () throws -> any CodexVoiceConnection = { try CodexVoiceRPC() },
         openURL: @escaping (URL) -> Bool = { ExternalLink.open($0) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.makeClient = makeClient; self.openURL = openURL; self.sleep = sleep
    }
    func refresh(force: Bool = false) {
        guard !isBusy, (!isConnected || force) else { return }
        run(state: .checking) { [self] id in try await ensureClient(id: id); try await readAccount(id: id) }
    }
    func connect() {
        guard !isBusy, !isConnected else { return }
        run(state: .checking) { [self] id in
            try await ensureClient(id: id); try await readAccount(id: id)
            guard generation == id, !isConnected else { return }
            state = .signingIn
            let result = try await client!.request("account/login/start", params: ["type": .string("chatgpt")], timeout: .seconds(20))
            guard generation == id, state == .signingIn else { return }
            guard let loginID = result["loginId"]?.stringValue,
                  let address = result["authUrl"]?.stringValue, let url = URL(string: address),
                  url.scheme == "https", ["auth.openai.com", "chatgpt.com", "login.openai.com"].contains(url.host?.lowercased() ?? "") else { throw CodexVoiceError.invalidResponse }
            self.loginID = loginID
            guard openURL(url) else { throw CodexVoiceError.signInRequired }
            loginTimer = Task { [weak self, sleep] in
                do { try await sleep(.seconds(300)) } catch { return }
                guard let self, self.generation == id, self.state == .signingIn else { return }
                self.fail(CodexVoiceError.timedOut)
            }
        }
    }
    func disconnect() {
        guard !isBusy else { return }
        onDisconnect?()
        run(state: .disconnecting) { [self] id in
            if let client { _ = try await client.request("account/logout", params: [:], timeout: .seconds(10)) }
            guard generation == id else { return }
            close(); plan = nil; email = nil; state = .signedOut
        }
    }
    func cancelSignIn() {
        guard state == .signingIn || state == .checking else { return }
        close(); state = .signedOut
    }
    func request(_ method: String, params: [String: JSONValue], timeout: Duration = .seconds(15)) async throws -> JSONValue {
        guard isConnected, let client else { throw CodexVoiceError.signInRequired }
        return try await client.request(method, params: params, timeout: timeout)
    }
    private func run(state: State, _ body: @escaping (UUID) async throws -> Void) {
        operation?.cancel(); errorMessage = nil; self.state = state
        let id = generation
        operation = Task { [weak self] in
            do { try await body(id) }
            catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }
    private func ensureClient(id: UUID) async throws {
        guard client == nil else { return }
        let client = try makeClient(); self.client = client
        client.onNotification = { [weak self] method, params in
            guard let self, self.generation == id else { return }
            if let thread = self.probeThreadID, params["threadId"]?.stringValue == thread {
                if method == "thread/realtime/started" { self.probeEvents?.yield(.available) }
                else if method == "thread/realtime/error" {
                    let message = params["message"]?.stringValue?.lowercased() ?? ""
                    self.probeEvents?.yield(message.contains("requires api key auth") ? .requiresAPIKey : .unavailable)
                } else if method == "thread/realtime/closed" { self.probeEvents?.yield(.unavailable) }
                return
            }
            if method == "account/login/completed" { self.loginCompleted(params) }
            else if method == "account/updated", params["authMode"]?.isNull == true, self.isConnected {
                self.close(); self.state = .signedOut; self.plan = nil; self.email = nil
            } else { self.onVoiceNotification?(method, params) }
        }
        client.onClose = { [weak self] in
            guard let self, self.generation == id else { return }; self.fail(CodexVoiceError.disconnected)
        }
        try await client.connect()
        guard generation == id else { throw CancellationError() }
        _ = try await client.request("thread/realtime/listVoices", params: [:], timeout: .seconds(15))
        guard generation == id else { throw CancellationError() }
    }
    private func readAccount(id: UUID) async throws {
        guard let client else { throw CodexVoiceError.disconnected }
        let result = try await client.request("account/read", params: ["refreshToken": .bool(false)], timeout: .seconds(15))
        guard generation == id else { return }
        let account = result["account"]
        if account?["type"]?.stringValue == "chatgpt" {
            plan = account?["planType"]?.stringValue; email = account?["email"]?.stringValue
            await checkVoiceAccess(id: id, client: client)
            guard generation == id else { return }
            state = .connected
        } else { plan = nil; email = nil; voiceAccess = .unknown; state = .signedOut }
    }
    /// A short, silent session checks actual service admission before enabling a microphone control.
    private func checkVoiceAccess(id: UUID, client: any CodexVoiceConnection) async {
        voiceAccess = .checking
        let (events, continuation) = AsyncStream<VoiceAccess>.makeStream(bufferingPolicy: .bufferingOldest(1))
        probeEvents = continuation
        let timer = Task { [sleep] in
            do { try await sleep(.seconds(15)) } catch { return }
            continuation.yield(.unavailable)
        }
        var result = VoiceAccess.unavailable
        do {
            let started = try await client.request("thread/start", params: [
                "ephemeral": .bool(true), "sandbox": .string("read-only"), "approvalPolicy": .string("never"),
                "developerInstructions": .string("Silent voice availability check. Do not speak, delegate, or use tools."),
                "config": .object(["web_search": .string("disabled")])
            ], timeout: .seconds(15))
            guard generation == id else { timer.cancel(); continuation.finish(); return }
            guard let thread = started["thread"]?["id"]?.stringValue else { throw CodexVoiceError.invalidResponse }
            probeThreadID = thread
            _ = try await client.request("thread/realtime/start", params: [
                "threadId": .string(thread), "outputModality": .string("audio"), "version": .string("v3"),
                "transport": .object(["type": .string("websocket")]), "includeStartupContext": .bool(false),
                "prompt": .string("Silent connection check. Wait for user audio.")
            ], timeout: .seconds(15))
            var iterator = events.makeAsyncIterator()
            result = await iterator.next() ?? .unavailable
        } catch { /* Unsupported voice never disconnects an otherwise valid ChatGPT account. */ }
        timer.cancel(); continuation.finish()
        guard generation == id else { return }
        let thread = probeThreadID; probeThreadID = nil; probeEvents = nil
        if let thread {
            _ = try? await client.request("thread/realtime/stop", params: ["threadId": .string(thread)], timeout: .seconds(3))
            _ = try? await client.request("thread/unsubscribe", params: ["threadId": .string(thread)], timeout: .seconds(3))
        }
        guard generation == id else { return }
        voiceAccess = result
    }
    private func loginCompleted(_ params: JSONValue) {
        guard state == .signingIn, params["loginId"]?.stringValue == loginID else { return }
        loginTimer?.cancel(); loginTimer = nil; loginID = nil
        probeEvents?.finish(); probeEvents = nil; probeThreadID = nil; voiceAccess = .unknown
        if params["success"]?.boolValue == true { run(state: .checking) { [self] id in try await readAccount(id: id) } }
        else { fail(CodexVoiceError.signInRequired) }
    }
    private func close() {
        generation = UUID(); operation?.cancel(); operation = nil
        loginTimer?.cancel(); loginTimer = nil; loginID = nil
        probeEvents?.finish(); probeEvents = nil; probeThreadID = nil; voiceAccess = .unknown
        onDisconnect?(); onVoiceNotification = nil; onDisconnect = nil
        client?.close(stopping: nil); client = nil
    }
    private func fail(_ error: Error) {
        close(); state = .idle; plan = nil; email = nil
        errorMessage = (error as? CodexVoiceError ?? .unavailable).localizedDescription
    }
}
