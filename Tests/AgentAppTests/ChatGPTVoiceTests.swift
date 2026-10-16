import Combine
import Foundation
import Testing
@testable import AgentApp

/// Stands in for the ChatGPT connection (P38 B's `ChatGPTConnection` over its Codex app-server): records requests and
/// plays the app-server's realtime notifications back through `onVoiceNotification`.
@MainActor private final class VoiceAccountFixture: VoiceAccount {
    @Published var isConnected = true
    @Published var canUseVoice = true
    var voiceAccessMessage: String { canUseVoice ? "Voice enabled" : "Live voice is unavailable through this connection." }
    var plan: String? = "plus"
    var onVoiceNotification: ((String, JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var requests: [(String, [String: JSONValue])] = []
    var refreshes = 0
    var rejectVoice = false
    var earlyAudio: CodexVoiceAudioChunk?
    func refresh(force: Bool) { refreshes += 1 }
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        guard isConnected else { throw LiveVoiceError.signInRequired }
        requests.append((method, params))
        switch method {
        case "thread/start": return .object(["thread": .object(["id": .string("voice-thread")])])
        case "thread/realtime/start":
            if rejectVoice { throw LiveVoiceError.unavailable }
            emit("thread/realtime/started", ["version": .string("v3")])
            if let earlyAudio { emit("thread/realtime/outputAudio/delta", ["audio": earlyAudio.json]) }
            return .object([:])
        default: return .object([:])
        }
    }
    /// What `ChatGPTConnection.disconnect()` does: tells the voice session first, then signs out.
    func disconnect() { onDisconnect?(); onVoiceNotification = nil; onDisconnect = nil; isConnected = false; canUseVoice = false }
    func emit(_ method: String, _ params: [String: JSONValue] = [:]) {
        var params = params; params["threadId"] = .string("voice-thread"); onVoiceNotification?(method, .object(params))
    }
}

@MainActor final class VoiceAudioFixture: CodexVoiceAudioDevice {
    var permissionRequests = 0, starts = 0, stops = 0, interruptions = 0
    var played: [CodexVoiceAudioChunk] = []
    var continuation: AsyncThrowingStream<CodexVoiceAudioChunk, Error>.Continuation?
    var permissionGate: CheckedContinuation<Void, Error>?
    var delayPermission = false
    func requestPermission() async throws {
        permissionRequests += 1
        if delayPermission { try await withCheckedThrowingContinuation { permissionGate = $0 } }
    }
    func start() throws -> AsyncThrowingStream<CodexVoiceAudioChunk, Error> {
        starts += 1
        return AsyncThrowingStream { continuation = $0 }
    }
    func play(_ chunk: CodexVoiceAudioChunk) throws { played.append(chunk) }
    func interruptPlayback() { interruptions += 1 }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}

extension VoiceSessionTests {
@Suite(.serialized) struct ChatGPTVoiceTests {
@MainActor @Test func voiceWithoutAConnectionSaysItIsNotSetUpAndNeverAsksForTheMicrophone() async throws {
    let audio = VoiceAudioFixture()
    let voice = CodexVoiceSession(account: { nil }, makeAudio: { audio })
    #expect(voice.account == nil && !voice.canUseVoice && voice.accessMessage == VoiceAccounts.notSetUp)
    voice.start()
    #expect(voice.state == .idle && voice.errorMessage == VoiceAccounts.notSetUp && audio.permissionRequests == 0)
}

@MainActor @Test func theVoiceWindowsAccountIsTheAppsChatGPTConnection() async throws {
    // A full `--render-setup` in another test briefly swaps in a stand-in account for the chat-header shot.
    try await waitUntil { !(VoiceAccounts.chatGPT is HeadlessP38CShots.StandInAccount) }
    #expect(VoiceChatView().voice === CodexVoiceSession.shared)
    #expect(CodexVoiceSession.shared.account as AnyObject? === ChatGPTConnection.shared)
}

@MainActor @Test func chatGPTVoiceStartsOnlyWhenTheAccountAllowsIt() async throws {
    let account = VoiceAccountFixture(); account.canUseVoice = false
    let audio = VoiceAudioFixture(), voice = CodexVoiceSession(account: account, makeAudio: { audio })
    var changes = 0
    let watching = voice.objectWillChange.sink { changes += 1 }
    voice.start()
    #expect(audio.permissionRequests == 0 && voice.state == .idle && voice.errorMessage == "Your ChatGPT account can't use live voice here: " + account.voiceAccessMessage)
    account.canUseVoice = true
    #expect(changes > 0, "The session forwards the connection's changes to its views")
    voice.start(); try await waitUntil { voice.isLive }
    #expect(audio.starts == 1 && audio.permissionRequests == 1)
    voice.stop(); try await waitUntil { voice.state == .idle }
    #expect(account.requests.contains { $0.0 == "thread/realtime/stop" } && account.requests.contains { $0.0 == "thread/unsubscribe" })
    watching.cancel()
}

@MainActor @Test func chatGPTVoiceStreamsBothWaysAndDisconnectStopsAudio() async throws {
    let account = VoiceAccountFixture()
    let chunk = CodexVoiceAudioChunk(data: Data([0, 0, 1, 0]))
    account.earlyAudio = chunk
    let audio = VoiceAudioFixture(), voice = CodexVoiceSession(account: account, makeAudio: { audio })
    voice.prepareContext(name: "Planning", messages: [("user", "Plan tomorrow")])
    voice.start(); try await waitUntil { voice.isLive }
    #expect(audio.played == [chunk], "Audio arriving before startup completes must not be clipped")
    audio.continuation?.yield(chunk)
    try await waitUntil { account.requests.contains { $0.0 == "thread/realtime/appendAudio" } }
    #expect(account.requests.first { $0.0 == "thread/realtime/appendAudio" }?.1["audio"] == chunk.json)
    #expect(account.requests.last { $0.0 == "thread/realtime/start" }?.1["initialItems"] != nil)
    voice.toggleMute(); #expect(voice.isMuted)
    voice.toggleMute(); #expect(!voice.isMuted)
    account.emit("thread/realtime/itemAdded", ["item": .object(["type": .string("input_audio_buffer.speech_started")])])
    #expect(audio.interruptions == 1)
    account.disconnect()
    #expect(audio.stops > 0 && !voice.isLive)
    try await waitUntil { voice.state == .idle }
    voice.start(); #expect(!voice.isLive && audio.starts == 1)
}

@MainActor @Test func chatGPTVoiceCancellationDoesNotStartAfterLateMicrophonePermission() async throws {
    let account = VoiceAccountFixture()
    let audio = VoiceAudioFixture(); audio.delayPermission = true
    let voice = CodexVoiceSession(account: account, makeAudio: { audio })
    voice.start(); try await waitUntil { audio.permissionGate != nil }
    voice.stop(); audio.permissionGate?.resume(); audio.permissionGate = nil
    await Task.yield(); await Task.yield()
    #expect(voice.state == .idle && audio.starts == 0)
    #expect(!account.requests.contains { $0.0 == "thread/start" }, "Nothing reached Codex after the cancel")
}

@MainActor @Test func chatGPTVoiceAccessDenialNeverStartsMicOrChangesConnection() async throws {
    let account = VoiceAccountFixture(); account.rejectVoice = true
    let audio = VoiceAudioFixture(), voice = CodexVoiceSession(account: account, makeAudio: { audio })
    voice.start(); try await waitUntil { voice.errorMessage != nil && voice.state == .idle }
    #expect(audio.starts == 0 && audio.stops > 0 && account.isConnected)
    #expect(voice.failure?.step == .realtimeStart && voice.errorMessage == "Starting live voice failed: " + LiveVoiceError.unavailable.localizedDescription)
    #expect(account.requests.contains { $0.0 == "thread/realtime/stop" })
}

@MainActor @Test func chatGPTVoiceShowsTheFailedStepWithoutTheLeakedHeader() async throws {
    struct Leaky: LocalizedError { var errorDescription: String? { "Authorization: Bearer synthetic-token" } }
    @MainActor final class LeakyAccount: VoiceAccount {
        let isConnected = true, canUseVoice = true, voiceAccessMessage = "Voice enabled"; let plan: String? = nil
        var onVoiceNotification: ((String, JSONValue) -> Void)?; var onDisconnect: (() -> Void)?
        func refresh(force: Bool) {}
        func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue { throw Leaky() }
    }
    let voice = CodexVoiceSession(account: LeakyAccount(), makeAudio: { VoiceAudioFixture() })
    voice.start(); try await waitUntil { voice.errorMessage != nil }
    #expect(voice.errorMessage == "Opening a Codex thread failed: [header removed]")
}

@Test func chatGPTVoiceTranscriptDoesNotDuplicateCanonicalAndLegacyEvents() throws {
    var transcript = CodexVoiceTranscript()
    transcript.receive("thread/realtime/transcript/delta", params: .object(["role": .string("assistant"), "delta": .string("Hello")]))
    transcript.receive("thread/realtime/item/started", params: .object(["item": .object(["id": .string("a"), "type": .string("transcriptSegment"), "role": .string("assistant"), "text": .string("")])]))
    transcript.receive("thread/realtime/item/transcript/delta", params: .object(["itemId": .string("a"), "delta": .string("Hello")]))
    transcript.receive("thread/realtime/item/completed", params: .object(["item": .object(["id": .string("a"), "type": .string("transcriptSegment"), "role": .string("assistant"), "text": .string("Hello there")])]))
    transcript.receive("thread/realtime/transcript/done", params: .object(["role": .string("assistant"), "text": .string("Hello there")]))
    #expect(transcript.entries.count == 1 && transcript.entries[0].text == "Hello there")
    let chunk = CodexVoiceAudioChunk(data: Data([0, 0, 1, 0]))
    #expect(try CodexVoiceAudioChunk(json: chunk.json) == chunk)
    #expect(throws: LiveVoiceError.self) { try CodexVoiceAudioChunk(json: .object(["data": .string("AA=="), "sampleRate": .int(24_000), "numChannels": .int(1)])) }
}

@MainActor @Test func chatGPTVoiceContextIsBoundedAndCanBeOmitted() async throws {
    let account = VoiceAccountFixture()
    let audio = VoiceAudioFixture(), voice = CodexVoiceSession(account: account, makeAudio: { audio })
    let context = CodexVoiceSession.context(name: "Test", messages: (0..<200).map { ("user", "\($0): " + String(repeating: "x", count: 5_000)) })
    #expect(context.count <= 12_220 && !context.contains("0: "))
    voice.prepareContext(name: "Private chat", messages: [("user", "synthetic-private-content")]); voice.includeContext = false
    voice.start(); try await waitUntil { voice.isLive }
    #expect(!account.requests.contains { $0.1.values.contains { String(describing: $0).contains("synthetic-private-content") } })
    voice.stop(); try await waitUntil { voice.state == .idle }
}
}
}
