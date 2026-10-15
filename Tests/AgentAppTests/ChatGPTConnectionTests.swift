import Foundation
import Testing
@testable import AgentApp

/// P38 B: the ChatGPT connected app over a fake Codex app-server; no Codex process, no browser, no network. The sign-in
/// and voice-check waits are injected and never elapse here.
@MainActor final class CodexRPCFixture: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    var signedIn = false
    var requests: [(String, [String: JSONValue])] = []
    var closed = false
    var requiresAPIKey = false
    var loginURL = "https://auth.openai.com/authorize"
    func connect() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        requests.append((method, params))
        switch method {
        case "account/read":
            return .object(["account": signedIn ? .object(["type": .string("chatgpt"), "planType": .string("plus"), "email": .string("voice@example.test")]) : .null])
        case "account/login/start": return .object(["loginId": .string("login-test"), "authUrl": .string(loginURL)])
        case "account/logout": signedIn = false; return .object([:])
        case "thread/start": return .object(["thread": .object(["id": .string("voice-thread")])])
        case "thread/realtime/start":
            if requiresAPIKey {
                emit("thread/realtime/error", ["message": .string("realtime conversation requires API key auth")])
                return .object([:])
            }
            emit("thread/realtime/started", ["version": .string("v3")])
            return .object([:])
        default: return .object([:])
        }
    }
    func close(stopping threadID: String?) { closed = true; onNotification = nil; onClose = nil }
    func login() { signedIn = true; onNotification?("account/login/completed", .object(["loginId": .string("login-test"), "success": .bool(true)])) }
    func emit(_ method: String, _ params: [String: JSONValue] = [:]) {
        var params = params; params["threadId"] = .string("voice-thread"); onNotification?(method, .object(params))
    }
}

private let neverElapses: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(86_400)) }

@MainActor @Test func chatGPTConnectsOnlyAfterTheBrowserSignInCompletes() async throws {
    let rpc = CodexRPCFixture(); var urls: [URL] = []
    let account = ChatGPTConnection(makeClient: { rpc }, openURL: { urls.append($0); return true }, sleep: neverElapses)
    account.connect()
    try await waitUntil { account.state == .signingIn }
    #expect(!account.isConnected && urls.map(\.host) == ["auth.openai.com"])
    rpc.login()
    try await waitUntil { account.isConnected }
    #expect(account.plan == "plus" && account.email == "voice@example.test" && account.canUseVoice)
    #expect(rpc.requests.contains { $0.0 == "thread/realtime/stop" }, "the silent voice check is closed again")
    account.disconnect(); try await waitUntil { account.state == .signedOut }
    #expect(rpc.requests.contains { $0.0 == "account/logout" } && rpc.closed)
}

@MainActor @Test func chatGPTCancelledSignInIgnoresALateCallback() async throws {
    let rpc = CodexRPCFixture()
    let account = ChatGPTConnection(makeClient: { rpc }, openURL: { _ in true }, sleep: neverElapses)
    account.connect(); try await waitUntil { account.state == .signingIn }
    let callback = rpc.onNotification
    account.cancelSignIn()
    callback?("account/login/completed", .object(["loginId": .string("login-test"), "success": .bool(true)]))
    #expect(account.state == .signedOut && !account.isConnected && rpc.closed)
}

@MainActor @Test func chatGPTSignInRefusesALinkOutsideOpenAI() async throws {
    let rpc = CodexRPCFixture(); rpc.loginURL = "https://auth.openai.com.evil.test/"; var opened = 0
    let account = ChatGPTConnection(makeClient: { rpc }, openURL: { _ in opened += 1; return true }, sleep: neverElapses)
    account.connect(); try await waitUntil { account.errorMessage != nil }
    #expect(opened == 0 && !account.isConnected)
}

@MainActor @Test func chatGPTSubscriptionWithoutVoiceStaysConnectedWithVoiceOff() async throws {
    let rpc = CodexRPCFixture(); rpc.signedIn = true; rpc.requiresAPIKey = true
    let account = ChatGPTConnection(makeClient: { rpc }, sleep: neverElapses); account.refresh()
    try await waitUntil { account.isConnected }
    #expect(account.voiceAccess == .requiresAPIKey && !account.canUseVoice)
    #expect(account.voiceAccessMessage.contains("requires an API key"))
    account.disconnect(); try await waitUntil { account.state == .signedOut }
}

@MainActor @Test func codexRPCHandlesFramingTimeoutAndCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "codex-rpc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "server")
    let script = #"""
    #!/usr/bin/python3
    import json, os, sys
    initialized = False
    for line in sys.stdin:
        msg = json.loads(line)
        if msg.get('method') == 'initialized':
            initialized = True
            continue
        if 'id' not in msg or msg['method'] == 'hang':
            continue
        if msg['method'] == 'initialize':
            assert msg['params']['capabilities']['experimentalApi']
            result = {}
        else:
            result = {'initialized': initialized, 'home': os.environ['CODEX_HOME'], 'apiKey': os.environ.get('OPENAI_API_KEY')}
        data = json.dumps({'id': msg['id'], 'result': result}) + '\n'
        sys.stdout.write(data[:7]); sys.stdout.flush()
        sys.stdout.write(data[7:]); sys.stdout.flush()
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let home = directory.appending(path: "home")
    let rpc = try CodexVoiceRPC(executable: executable, home: home)
    defer { rpc.close(stopping: nil) }
    try await rpc.connect()
    let result = try await rpc.request("probe")
    #expect(result["initialized"]?.boolValue == true && result["home"]?.stringValue == home.path)
    #expect(result["apiKey"] == .null, "an inherited API key never reaches the subscription connection")
    await #expect(throws: CodexVoiceError.timedOut) { try await rpc.request("hang", timeout: .milliseconds(30)) }
    let cancelled = Task { try await rpc.request("hang") }
    await Task.yield(); cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(try await rpc.request("probe")["initialized"]?.boolValue == true)
}
