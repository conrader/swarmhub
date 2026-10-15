import AVFoundation
import Combine
import Foundation

/// P38 C: one dictation recording. Tests inject a fake.
@MainActor protocol DictationRecording: AnyObject {
    var isRecording: Bool { get }
    var duration: TimeInterval { get }
    var onFinish: ((Bool) -> Void)? { get set }
    func start() throws
    func stop() -> URL
    func discard()
}

/// 16 kHz mono WAV in a private temporary folder (0700/0600), removed after transcription or cancellation.
@MainActor private final class WAVDictationRecording: NSObject, DictationRecording, AVAudioRecorderDelegate {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SwarmHub-voice-\(UUID().uuidString)")
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var finishedDuration: TimeInterval?
    var onFinish: ((Bool) -> Void)?
    private var url: URL { directory.appending(path: "dictation.wav") }
    var isRecording: Bool { recorder?.isRecording ?? false }
    var duration: TimeInterval { finishedDuration ?? recorder?.currentTime ?? 0 }
    func start() throws {
        if TestRunGuard.refuses("microphone (dictation)") { throw VoiceDictationError.recordingFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let recording = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        recorder = recording
        recording.delegate = self
        startedAt = .now
        guard recording.prepareToRecord(), recording.record(forDuration: VoiceDictation.limit) else { throw VoiceDictationError.recordingFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func stop() -> URL { finishedDuration = duration; recorder?.stop(); return url }
    func discard() { onFinish = nil; recorder?.delegate = nil; recorder?.stop(); recorder = nil; try? FileManager.default.removeItem(at: directory) }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == id else { return }
            if self.finishedDuration == nil { self.finishedDuration = min(VoiceDictation.limit, self.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0) }
            self.onFinish?(flag)
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == id else { return }
            self.onFinish?(false)
        }
    }
}

enum VoiceDictationError: LocalizedError {
    case permissionDenied, bundleRequired, recordingFailed
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow microphone access for SwarmHub in System Settings → Privacy & Security → Microphone."
        case .bundleRequired: "Open SwarmHub from its application bundle to use the microphone."
        case .recordingFailed: "Could not record audio. Check your microphone and try again."
        }
    }
}

/// Dictation into a composer: record, stop, deAPI transcribes, the text is appended to the draft for review (never
/// sent). One session per chat; cancellation invalidates late permission and network callbacks.
@MainActor final class VoiceDictation: ObservableObject {
    static let limit: TimeInterval = 300
    enum State: Equatable { case idle, requestingPermission, recording, transcribing }
    @Published private(set) var state = State.idle
    @Published private(set) var elapsed = 0
    @Published private(set) var transcript: String?
    private(set) var transcriptContext: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsConfiguration = false
    @Published private(set) var needsMicrophonePermission = false
    var isBusy: Bool { state != .idle }
    var elapsedText: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }
    private static weak var active: VoiceDictation?
    private var sessionID: UUID?
    private var operation: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var recording: (any DictationRecording)?
    private var recordingKey: String?
    private var recordingContext = ""
    private let key: () -> String
    private let permission: @Sendable () async throws -> Bool
    private let makeRecording: () -> any DictationRecording
    private let transcribe: @Sendable (URL, String) async throws -> String
    private let sleep: @Sendable (Duration) async throws -> Void

    init(key: @escaping () -> String = { KeychainStore.get(account: DeAPICredentials.account) },
         permission: @escaping @Sendable () async throws -> Bool = VoiceDictation.requestMicrophone,
         makeRecording: @escaping () -> any DictationRecording = { WAVDictationRecording() },
         transcribe: @escaping @Sendable (URL, String) async throws -> String = { try await DeAPIClient(apiKey: $1).transcribe(file: $0) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.key = key; self.permission = permission; self.makeRecording = makeRecording; self.transcribe = transcribe; self.sleep = sleep
    }

    /// The key is read only here, when the user presses the microphone.
    func start(context: String = "") {
        guard !isBusy else { return }
        cancel()
        let apiKey = key().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { fail(DeAPIError.missingKey); return }
        CodexVoiceSession.stopActive()
        Self.active?.cancel(); Self.active = self
        recordingKey = apiKey
        recordingContext = context
        let id = UUID(); sessionID = id; state = .requestingPermission
        operation = Task { [weak self, permission, sleep] in
            do {
                let granted = try await permission()
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                guard granted else { throw VoiceDictationError.permissionDenied }
                let recording = self.makeRecording(); self.recording = recording
                recording.onFinish = { [weak self] success in
                    guard let self, self.sessionID == id, self.state == .recording else { return }
                    if success { self.finish() } else { self.fail(VoiceDictationError.recordingFailed) }
                }
                try recording.start()
                self.state = .recording
                self.clock = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await sleep(.seconds(1)) } catch { return }
                        guard let self, self.sessionID == id, self.state == .recording else { return }
                        self.elapsed = Int(self.recording?.duration ?? 0)
                        if Double(self.elapsed) >= Self.limit { self.finish(); return }
                    }
                }
            } catch {
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func finish() {
        guard state == .recording, let recording, let id = sessionID, let apiKey = recordingKey else { return }
        clock?.cancel(); clock = nil
        guard recording.duration >= 0.35 else { fail(DeAPIError.noSpeech); return }
        let url = recording.stop()
        state = .transcribing
        operation = Task { [weak self, transcribe] in
            do {
                let value = try await transcribe(url, apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                guard !value.isEmpty else { throw DeAPIError.noSpeech }
                self.recording?.discard(); self.recording = nil
                self.recordingKey = nil
                self.sessionID = nil; self.operation = nil; self.state = .idle
                self.transcriptContext = self.recordingContext
                self.transcript = value
            } catch {
                guard let self, self.sessionID == id, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func cancel() {
        sessionID = nil
        operation?.cancel(); operation = nil; clock?.cancel(); clock = nil
        recording?.discard(); recording = nil
        recordingKey = nil
        state = .idle; elapsed = 0; transcriptContext = nil; transcript = nil
        errorMessage = nil; needsConfiguration = false; needsMicrophonePermission = false
    }
    static func cancelActive() { active?.cancel() }
    private func fail(_ error: Error) {
        cancel()
        errorMessage = error.localizedDescription
        if let error = error as? DeAPIError {
            switch error { case .missingKey, .http(401), .http(403): needsConfiguration = true; default: break }
        }
        if case VoiceDictationError.permissionDenied = error { needsMicrophonePermission = true }
    }
    static func appending(_ transcript: String, to draft: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return draft }
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + spoken
    }
    /// The one microphone permission path (dictation and live voice). A test run never asks.
    nonisolated static func requestMicrophone() async throws -> Bool {
        if TestRunGuard.refuses("microphone permission") { return false }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else { throw VoiceDictationError.bundleRequired }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }
}
