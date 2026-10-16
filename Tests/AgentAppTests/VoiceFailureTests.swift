import AppKit
import Foundation
import Testing
@testable import AgentApp

/// P55: a fake ChatGPT connection (no Codex app-server) that fails the step a test names; requests are recorded and
/// realtime notifications are played back through `onVoiceNotification`.
@MainActor private final class FailingVoiceAccount: VoiceAccount {
    @Published var isConnected = true
    @Published var canUseVoice = true
    var voiceAccessMessage = "Voice enabled"
    let plan: String? = "plus"
    var onVoiceNotification: ((String, JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var requests: [String] = []
    /// Thrown by that method's request.
    var failures: [String: Error] = [:]
    /// Sent in place of `thread/realtime/started`.
    var startNotification: (String, [String: JSONValue])?
    func refresh(force: Bool) {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        requests.append(method)
        if let error = failures[method] { throw error }
        switch method {
        case "thread/start": return .object(["thread": .object(["id": .string("p55-thread")])])
        case "thread/realtime/start":
            let (name, extra) = startNotification ?? ("thread/realtime/started", ["version": .string("v3")])
            var params = extra; params["threadId"] = .string("p55-thread")
            onVoiceNotification?(name, .object(params))
            return .object([:])
        default: return .object([:])
        }
    }
}

/// Never opens the microphone: permission and start fail or succeed as told.
@MainActor private final class FailingAudio: CodexVoiceAudioDevice {
    var permission: Error?, starting: Error?
    var starts = 0
    var continuation: AsyncThrowingStream<CodexVoiceAudioChunk, Error>.Continuation?
    func requestPermission() async throws { if let permission { throw permission } }
    func start() throws -> AsyncThrowingStream<CodexVoiceAudioChunk, Error> {
        starts += 1
        if let starting { throw starting }
        return AsyncThrowingStream { continuation = $0 }
    }
    func play(_ chunk: CodexVoiceAudioChunk) throws {}
    func interruptPlayback() {}
    func stop() { continuation?.finish(); continuation = nil }
}

extension VoiceSessionTests {
@Suite(.serialized) struct VoiceFailureTests {
    @MainActor private func failing(_ configure: (FailingVoiceAccount, FailingAudio) -> Void) async throws -> (CodexVoiceSession, [String], FailingAudio) {
        let account = FailingVoiceAccount(), audio = FailingAudio()
        configure(account, audio)
        let voice = CodexVoiceSession(account: account, makeAudio: { audio })
        var lines: [String] = []
        voice.onLog = { lines.append($0) }
        voice.start(); try await waitUntil { voice.failure != nil && voice.state == .idle }
        return (voice, lines, audio)
    }

    @MainActor @Test func eachStepsFailureShowsItsOwnTextAndIsLogged() async throws {
        let refusal = CodexRPCError(code: -32000, message: "realtime is not enabled for this workspace")
        let cases: [(LiveVoiceFailure.Step, String, (FailingVoiceAccount, FailingAudio) -> Void)] = [
            (.account, "Your ChatGPT account can't use live voice here: Voice is off for this workspace.",
             { account, _ in account.canUseVoice = false; account.voiceAccessMessage = "Voice is off for this workspace." }),
            (.microphone, "Microphone access is off for SwarmHub — turn it on in System Settings → Privacy & Security → Microphone.",
             { _, audio in audio.permission = VoiceDictationError.permissionDenied }),
            (.threadStart, "ChatGPT refused live voice: -32000 realtime is not enabled for this workspace",
             { account, _ in account.failures["thread/start"] = refusal }),
            (.realtimeStart, "ChatGPT refused live voice: -32000 realtime is not enabled for this workspace",
             { account, _ in account.failures["thread/realtime/start"] = refusal }),
            (.realtimeStart, "Codex did not answer within 30 s (starting live voice).",
             { account, _ in account.failures["thread/realtime/start"] = CodexVoiceError.timedOut }),
            (.audioDevice, "The audio device could not start: the input device has no audio format",
             { _, audio in audio.starting = VoiceAudioStartError(reason: "the input device has no audio format") }),
            (.realtimeStart, "ChatGPT refused live voice: 403 Your plan does not include voice.",
             { account, _ in account.startNotification = ("thread/realtime/error", ["message": .string("Your plan does not include voice."), "code": .int(403)]) }),
            (.realtimeStart, "ChatGPT closed live voice before it started: upstream websocket closed",
             { account, _ in account.startNotification = ("thread/realtime/closed", ["reason": .string("upstream websocket closed")]) })
        ]
        for (step, text, configure) in cases {
            let (voice, lines, audio) = try await failing(configure)
            #expect(voice.failure?.step == step && voice.errorMessage == text, "\(step): \(voice.errorMessage ?? "nil")")
            #expect(lines.contains { $0.hasPrefix("voice failed step=\(step.rawValue) type=") }, "\(step) is logged: \(lines)")
            #expect(lines.filter { $0.hasPrefix("voice failed") }.count == 1, "one failure line: \(lines)")
            if step != .audioDevice { #expect(audio.starts == 0, "\(step) never reached the audio device") }
        }
    }

    @MainActor @Test func theFailureLogLineCarriesStepTypeCodeAndRedactedMessage() async throws {
        let (voice, lines, _) = try await failing { account, _ in
            account.failures["thread/realtime/start"] = CodexRPCError(code: -32001, message: "denied at https://chatgpt.com/backend/realtime?session=abc&sig=xyz; Authorization: Bearer sk-synthetic1234567890")
        }
        let line = try #require(lines.last)
        #expect(line == #"voice failed step=thread/realtime/start type=CodexRPCError code=-32001 message="denied at https://chatgpt.com/backend/realtime; [header removed]""#)
        #expect(!voice.errorMessage!.contains("sk-synthetic") && !voice.errorMessage!.contains("sig="))
        #expect(["account", "microphone", "thread/start", "thread/realtime/start"].allSatisfy { step in lines.contains("voice step=\(step) started") },
                "each step's start is logged: \(lines)")
    }

    @MainActor @Test func aDisconnectWhileLiveSaysTheConnectionClosed() async throws {
        let account = FailingVoiceAccount(), audio = FailingAudio()
        let voice = CodexVoiceSession(account: account, makeAudio: { audio })
        voice.start(); try await waitUntil { voice.isLive }
        account.onDisconnect?(); account.isConnected = false
        try await waitUntil { voice.state == .idle }
        #expect(voice.errorMessage == "The ChatGPT connection closed during: sending your voice. Reconnect ChatGPT and try again.")
        account.isConnected = true
        account.failures["thread/realtime/appendAudio"] = CodexVoiceError.timedOut
        voice.start(); try await waitUntil { voice.isLive }
        #expect(voice.failure == nil, "starting again clears the old failure")
        audio.continuation?.yield(CodexVoiceAudioChunk(data: Data([0, 0])))
        try await waitUntil { voice.failure != nil && voice.state == .idle }
        #expect(voice.errorMessage == "Codex did not answer within 5 s (sending your voice).")
    }

    @MainActor @Test func theErrorStaysAfterStopUntilDismissedAndCopiesItsDetails() async throws {
        let (voice, _, _) = try await failing { account, _ in
            account.failures["thread/start"] = CodexRPCError(code: -32603, message: "internal error\nx-request-id: req_123\nset-cookie: __Secure-token=abc")
        }
        let failure = try #require(voice.failure)
        voice.stop(); CodexVoiceSession.stopActive()
        #expect(voice.failure == failure, "stopping again keeps the error shown")
        var copied: [String] = []
        voice.copyDetails { copied.append($0) }
        #expect(copied == ["SwarmHub live voice failure\nStep: Opening a Codex thread (thread/start)\nError: CodexRPCError\nCode: -32603\nMessage: internal error [header removed] [header removed]"])
        voice.dismissFailure()
        #expect(voice.failure == nil && voice.errorMessage == nil)
        voice.copyDetails { copied.append($0) }
        #expect(copied.count == 1, "nothing to copy once dismissed")
    }

    @MainActor @Test func microphoneOffOffersItsSettingsPane() async throws {
        let (voice, _, _) = try await failing { _, audio in audio.permission = VoiceDictationError.permissionDenied }
        #expect(voice.failure?.opensMicrophoneSettings == true)
        #expect(ExternalLink.microphoneSettings.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        let (other, _, _) = try await failing { account, _ in account.failures["thread/start"] = CodexVoiceError.disconnected }
        #expect(other.failure?.opensMicrophoneSettings == false)
    }

    @Test func redactionStripsTokensHeadersAndQueryStrings() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl"
        let cases = [
            ("Authorization: Bearer abc.def", "[header removed]"),
            ("failed with bearer abcdef123456", "failed with [credential removed]"),
            ("token \(jwt) expired", "token [token removed] expired"),
            ("key sk-proj-abcdefghijkl rejected", "key [key removed] rejected"),
            (#"{"access_token":"s3cr3t","ok":false}"#, #"{"access_token":"[removed]","ok":false}"#),
            ("password=hunter2&user=me", "password=[removed]&user=me"),
            ("see https://auth.openai.com/oauth?code=xyz&state=1#frag now", "see https://auth.openai.com/oauth now"),
            ("id 0123456789abcdef0123456789abcdef01", "id [token removed]"),
            ("line one\nline\ttwo\r\n", "line one line two"),
            ("error code 429: rate limited", "error code 429: rate limited"),
            ("Cookie: a=1; __Secure-next-auth.session-token=abc, more\nnext line", "[header removed] next line"),
            ("via https://user:pa55@proxy.example/x ok", "via https://proxy.example/x ok"),
            ("account voice@example.test is on Free", "account [email removed] is on Free"),
            ("GET chatgpt.com/backend-api/realtime?sig=abc&exp=1 failed", "GET chatgpt.com/backend-api/realtime failed")
        ]
        for (input, expected) in cases { #expect(VoiceRedaction.redact(input) == expected, "\(input)") }
        let long = VoiceRedaction.redact(String(repeating: "word ", count: 200))
        #expect(long.count == 300 && long.hasSuffix("…"))
    }

    @MainActor @Test func p55ShotsRenderTheMicrophoneAndRefusalErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppP55-\(UUID().uuidString)")
        var lines: [String] = []
        #expect(await HeadlessSetup.render(to: directory, only: "p55", output: { lines.append($0) }) == 0, "\(lines)")
        for name in HeadlessP55Shots.names {
            let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
            #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP55Shots.names.count, "only the P55 shots")
    }

    @Test func aJSONRPCErrorsOwnDescriptionIsAFixedLine() {
        let error = CodexRPCError(code: -32602, message: "Authorization: Bearer leaked")
        #expect(error.fallback == .invalidResponse && error.localizedDescription == CodexVoiceError.invalidResponse.localizedDescription)
        #expect(CodexRPCError(code: -32000, message: "x").fallback == .unavailable)
    }
}
}
