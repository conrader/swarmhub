// P38 C: deAPI dictation (client, lifecycle, composer). deAPI is served by `MockHermesProtocol`; no key, microphone or network.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentApp

private let dictationKey = "synthetic-dictation-key"

private func dictationAudio() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dictation-test-\(UUID().uuidString).wav")
    try Data(repeating: 42, count: 128).write(to: url)
    return url
}

private func dictationClient(_ handler: @escaping MockHermesProtocol.Handler) -> (DeAPIClient, String) {
    let (host, session) = MockHermesProtocol.serve(handler)
    return (DeAPIClient(apiKey: "dpn-sk-" + dictationKey, session: session,
                        baseURL: URL(string: "https://\(host)/api/v2/")!, pollInterval: .zero, sleep: { _ in }), host)
}

private func dictationModels() -> [String: Any] {
    ["data": [["slug": "CurrentWhisper", "inference_types": ["audio_file2text"]]], "meta": ["last_page": 1]]
}

private func dictationRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

@Test func deAPIDictationDiscoversModelUploadsAudioAndPolls() async throws {
    let log = LockedTrace()
    let (client, host) = dictationClient { request in
        switch request.url!.path {
        case "/api/v2/models": return (200, dictationModels())
        case "/api/v2/audio/transcriptions":
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            let upload = String(decoding: dictationRequestBody(request), as: UTF8.self)
            #expect(upload.contains("name=\"source_file\"; filename=\"dictation.wav\""))
            #expect(upload.contains("name=\"model\"\r\n\r\nCurrentWhisper"))
            return (200, ["data": ["request_id": "dictation-job-1"]])
        case "/api/v2/jobs/dictation-job-1":
            let first = log.read().isEmpty; log.add("poll")
            return (200, ["data": first ? ["status": "processing"] : ["status": "done", "result": "  Hello, team.  "]])
        default: return (404, [:])
        }
    }
    let audio = try dictationAudio(); defer { try? FileManager.default.removeItem(at: audio) }
    #expect(try await client.transcribe(file: audio) == "Hello, team.")
    let requests = MockHermesProtocol.recorded(host)
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + dictationKey })
    #expect(requests[0].url?.query?.contains("limit=50") == true)
    let boundary = "test-boundary"
    let body = DeAPIClient.multipart(audio: Data([0, 1, 2, 255]), model: "CurrentWhisper", boundary: boundary)
    let header = String(decoding: body, as: UTF8.self)
    #expect(header.contains("name=\"source_file\"; filename=\"dictation.wav\""))
    #expect(header.contains("name=\"model\"\r\n\r\nCurrentWhisper"))
    #expect(header.contains("name=\"include_ts\"\r\n\r\n0"))
    #expect(body.range(of: Data([0, 1, 2, 255])) != nil)
    #expect(header.hasSuffix("--test-boundary--\r\n"))
}

@Test func deAPIModelDiscoveryHandlesPaginationAndUnsupportedModels() async throws {
    let (client, host) = dictationClient { request in
        if request.url?.query?.contains("page=1") == true {
            return (200, ["data": [["slug": "ImageModel", "inference_types": ["txt2img"]]], "meta": ["last_page": 2]])
        }
        return (200, ["data": [["slug": "FreshWhisper", "inference_types": ["audio_file2text"]]], "meta": ["last_page": 2]])
    }
    #expect(try await client.transcriptionModel() == "FreshWhisper")
    #expect(MockHermesProtocol.recorded(host).count == 2)
    let (empty, _) = dictationClient { _ in (200, ["data": [], "meta": ["last_page": 1]]) }
    await #expect(throws: DeAPIError.noModel) { try await empty.transcriptionModel() }
}

@Test func deAPIDictationReportsFailedEmptyTimedOutAndMalformedJobs() async throws {
    let audio = try dictationAudio(); defer { try? FileManager.default.removeItem(at: audio) }
    for (job, expected) in [
        (["status": "error", "error_reason": "provider-secret"], DeAPIError.jobFailed),
        (["status": "done", "result": "  \n"], .noSpeech),
        (["status": "pending"], .timedOut),
        (["status": "unexpected"], .invalidResponse),
        (["status": "done", "result_url": "http://unsafe.test/transcript.txt"], .invalidResponse)
    ] {
        var (client, _) = dictationClient { request in
            if request.url?.path.hasSuffix("models") == true { return (200, dictationModels()) }
            if request.httpMethod == "POST" { return (200, ["data": ["request_id": "job"]]) }
            return (200, ["data": job])
        }
        client.pollTimeout = .zero
        await #expect(throws: expected) { try await client.transcribe(file: audio) }
    }
}

@Test func deAPIResultDownloadNeverSendsTheAPIKey() async throws {
    let audio = try dictationAudio(); defer { try? FileManager.default.removeItem(at: audio) }
    let (client, host) = dictationClient { request in
        if request.url?.path.hasSuffix("models") == true { return (200, dictationModels()) }
        if request.httpMethod == "POST" { return (200, ["data": ["request_id": "job"]]) }
        if request.url?.path.contains("jobs") == true { return (200, ["data": ["status": "done", "result_url": "https://\(request.url!.host!)/transcript.txt"]]) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (200, ["synthetic": "download"])
    }
    _ = try await client.transcribe(file: audio)
    let download = try #require(MockHermesProtocol.recorded(host).last)
    #expect(download.url?.path == "/transcript.txt" && download.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func deAPIDictationErrorsDoNotExposeResponseSecrets() async throws {
    let (client, _) = dictationClient { _ in (401, ["message": "secret: " + dictationKey]) }
    do { _ = try await client.transcriptionModel(); Issue.record("Expected authentication failure") }
    catch { #expect(error as? DeAPIError == .http(401)); #expect(!error.localizedDescription.contains(dictationKey)) }
    let audio = try dictationAudio(); defer { try? FileManager.default.removeItem(at: audio) }
    await #expect(throws: DeAPIError.missingKey) { try await DeAPIClient(apiKey: " ").transcribe(file: audio) }
}

@MainActor private final class FakeDictationRecording: DictationRecording {
    var isRecording = false
    var duration: TimeInterval = 1
    var discarded = false
    var onFinish: ((Bool) -> Void)?
    let url: URL
    init() throws { url = try dictationAudio() }
    func start() throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data(repeating: 42, count: 128).write(to: url) }
        discarded = false; isRecording = true
    }
    func stop() -> URL { isRecording = false; return url }
    func discard() { onFinish = nil; isRecording = false; discarded = true; try? FileManager.default.removeItem(at: url) }
}

private actor DictationGate<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?
    func wait() async -> T { await withCheckedContinuation { continuation = $0 } }
    func waiting() -> Bool { continuation != nil }
    func release(_ value: T) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor private final class DictationDraft: ObservableObject {
    @Published var text = "Typed draft"
    @Published var attachments: [ChatAttachment] = []
    @Published var context = "chat-a"
}

private struct DictationComposerFixture: View {
    @ObservedObject var draft: DictationDraft
    let voice: VoiceDictation
    var body: some View {
        ComposerView(text: $draft.text, attachments: $draft.attachments, isStreaming: false, send: {}, stop: {},
                     dictationContext: draft.context, dictation: voice)
    }
}

extension VoiceSessionTests {
@Suite(.serialized) @MainActor struct VoiceDictationLifecycleTests {
    @Test func dictationPreservesDraftAndCleansTheRecording() async throws {
        let recording = try FakeDictationRecording()
        let gate = DictationGate<String>()
        let voice = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { recording }, transcribe: { _, _ in await gate.wait() })
        voice.start(); try await waitUntil { voice.state == .recording }
        voice.finish(); try await waitUntil { await gate.waiting() }
        #expect(voice.state == .transcribing)
        await gate.release("  Spoken words.  ")
        try await waitUntil { voice.state == .idle }
        let transcript = try #require(voice.transcript)
        #expect(transcript == "Spoken words.")
        #expect(VoiceDictation.appending(transcript, to: "@Atlas typed draft") == "@Atlas typed draft Spoken words.")
        #expect(VoiceDictation.appending("Hello", to: "Line one\n") == "Line one\nHello")
        #expect(VoiceDictation.appending("  ", to: "unchanged") == "unchanged")
        #expect(recording.discarded && !FileManager.default.fileExists(atPath: recording.url.path))
    }

    @Test func dictationCancellationIgnoresLateResultsAndPermission() async throws {
        let recording = try FakeDictationRecording()
        let gate = DictationGate<String>()
        let voice = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { recording }, transcribe: { _, _ in await gate.wait() })
        voice.start(); try await waitUntil { voice.state == .recording }
        voice.finish(); try await waitUntil { await gate.waiting() }
        voice.cancel(); await gate.release("Must not reach another chat")
        #expect(voice.state == .idle && voice.transcript == nil && recording.discarded)
        let permissionGate = DictationGate<Bool>()
        let pending = VoiceDictation(key: { dictationKey }, permission: { await permissionGate.wait() }, makeRecording: { recording })
        pending.start(); try await waitUntil { await permissionGate.waiting() }
        pending.cancel(); await permissionGate.release(true)
        #expect(pending.state == .idle && !recording.isRecording)
    }

    @Test func dictationHandlesMissingKeyDeniedPermissionAndShortRecordings() async throws {
        let missing = VoiceDictation(key: { "" }, permission: { Issue.record("Permission must not be requested without a key"); return true })
        missing.start()
        #expect(missing.state == .idle && missing.needsConfiguration)
        let denied = VoiceDictation(key: { dictationKey }, permission: { false })
        denied.start(); try await waitUntil { denied.errorMessage != nil }
        #expect(denied.state == .idle && denied.needsMicrophonePermission)
        let recording = try FakeDictationRecording(); recording.duration = 0.1
        let short = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { recording }, transcribe: { _, _ in Issue.record("Short audio must not be uploaded"); return "" })
        short.start(); try await waitUntil { short.state == .recording }; short.finish()
        #expect(short.state == .idle && short.errorMessage != nil && recording.discarded)
    }

    @Test func startingAnotherComposerDiscardsThePreviousRecording() async throws {
        let firstRecording = try FakeDictationRecording(), secondRecording = try FakeDictationRecording()
        let first = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { firstRecording })
        let second = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { secondRecording })
        first.start(); try await waitUntil { first.state == .recording }
        second.start(); try await waitUntil { second.state == .recording }
        #expect(first.state == .idle && firstRecording.discarded)
        second.cancel()
    }

    @Test func dictationAutomaticStopAndEncoderFailureCleanUp() async throws {
        let recording = try FakeDictationRecording()
        let voice = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { recording }, transcribe: { _, _ in "At the time limit" })
        voice.start(); try await waitUntil { voice.state == .recording }
        recording.duration = 300; recording.isRecording = false; recording.onFinish?(true)
        try await waitUntil { voice.transcript != nil }
        #expect(voice.transcript == "At the time limit" && recording.discarded)
        voice.start(); try await waitUntil { voice.state == .recording }
        recording.onFinish?(false)
        #expect(voice.state == .idle && voice.errorMessage != nil && recording.discarded)
    }

    @Test func dictationComposerPreservesEditsAndCancelsWhenConversationChanges() async throws {
        _ = NSApplication.shared
        let recording = try FakeDictationRecording()
        let gate = DictationGate<String>(), returned = AwaitableLog<String>()
        let voice = VoiceDictation(key: { dictationKey }, permission: { true }, makeRecording: { recording }, transcribe: { _, _ in
            let text = await gate.wait(); returned.append(text); return text
        })
        let draft = DictationDraft()
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let host = NSHostingView(rootView: DictationComposerFixture(draft: draft, voice: voice).environmentObject(store).frame(width: 600, height: 170))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 170), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { voice.cancel(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); await Task.yield()
        voice.start(context: draft.context); try await waitUntil { voice.state == .recording }
        voice.finish(); try await waitUntil { await gate.waiting() }
        draft.text = "Edited while transcribing"
        await gate.release("Spoken words")
        try await waitUntil { draft.text == "Edited while transcribing Spoken words" }
        voice.start(context: draft.context); try await waitUntil { voice.state == .recording }
        voice.finish(); try await waitUntil { await gate.waiting() }
        draft.context = "chat-b"
        try await waitUntil { voice.state == .idle }
        await gate.release("Must not enter the next chat")
        try await returned.wait { $0.count == 2 }; await Task.yield()
        #expect(draft.text == "Edited while transcribing Spoken words" && voice.transcript == nil && recording.discarded)
    }
}
}
