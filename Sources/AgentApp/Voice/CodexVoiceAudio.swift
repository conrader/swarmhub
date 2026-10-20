@preconcurrency import AVFoundation
import Foundation

/// P38 C: the microphone and speaker of a live voice conversation. Tests inject a fake.
@MainActor protocol CodexVoiceAudioDevice: AnyObject {
    func requestPermission() async throws
    func start() throws -> AsyncThrowingStream<CodexVoiceAudioChunk, Error>
    func play(_ chunk: CodexVoiceAudioChunk) throws
    func interruptPlayback()
    func stop()
}

/// P55: why the audio engine did not start, for "The audio device could not start: <reason>".
struct VoiceAudioStartError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Input and output share a voice-processing engine, so speaker output can be cancelled from mic input.
/// A test run never reaches the microphone (P28 `TestRunGuard`).
@MainActor final class CodexVoiceAudio: CodexVoiceAudioDevice {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: Capture?
    private var hasTap = false
    private var queuedSeconds: Double = 0
    private var playbackGeneration = UUID()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func requestPermission() async throws {
        guard try await VoiceDictation.requestMicrophone() else { throw VoiceDictationError.permissionDenied }
    }

    func start() throws -> AsyncThrowingStream<CodexVoiceAudioChunk, Error> {
        stop()
        if TestRunGuard.refuses("microphone (live voice)") { throw LiveVoiceError.audioUnavailable }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        self.engine = engine; self.player = player
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceAudioStartError(reason: "the input device has no audio format (is a microphone connected?)") }
            let (stream, continuation) = AsyncThrowingStream<CodexVoiceAudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
            let capture = try Capture(inputFormat: format, continuation: continuation)
            self.capture = capture
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format, block: capture.tap())
            hasTap = true
            engine.prepare(); try engine.start(); player.play()
            return stream
        } catch let error as VoiceAudioStartError { stop(); throw error }
        catch { stop(); let error = error as NSError; throw VoiceAudioStartError(reason: "\(error.localizedDescription) (\(error.domain) \(error.code))") }
    }

    func play(_ chunk: CodexVoiceAudioChunk) throws {
        guard let player, engine?.isRunning == true,
              let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(chunk.sampleRate), channels: AVAudioChannelCount(chunk.channels), interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(chunk.data.count / (2 * chunk.channels))),
              let converter = AVAudioConverter(from: source, to: playbackFormat) else { throw LiveVoiceError.audioUnavailable }
        input.frameLength = input.frameCapacity
        let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        guard let destination = buffers.first?.mData else { throw LiveVoiceError.audioUnavailable }
        chunk.data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: chunk.data.count)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / Double(chunk.sampleRate))) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else { throw LiveVoiceError.audioUnavailable }
        var consumed = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { throw LiveVoiceError.audioUnavailable }
        let duration = Double(output.frameLength) / 24_000
        guard queuedSeconds + duration <= 10 else { throw LiveVoiceError.audioUnavailable }
        queuedSeconds += duration
        let generation = playbackGeneration
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - duration)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func interruptPlayback() {
        playbackGeneration = UUID(); queuedSeconds = 0
        player?.stop()
        if engine?.isRunning == true { player?.play() }
    }

    func stop() {
        capture?.finish(); capture = nil
        if let engine { if hasTap { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        hasTap = false
        player?.stop(); player = nil; engine = nil
        playbackGeneration = UUID(); queuedSeconds = 0
    }

    /// AVAudioEngine serializes tap callbacks. The converter is used only on that audio callback queue.
    private final class Capture: @unchecked Sendable {
        let converter: AVAudioConverter
        let format: AVAudioFormat
        let continuation: AsyncThrowingStream<CodexVoiceAudioChunk, Error>.Continuation
        init(inputFormat: AVAudioFormat, continuation: AsyncThrowingStream<CodexVoiceAudioChunk, Error>.Continuation) throws {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
            guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw LiveVoiceError.audioUnavailable }
            self.converter = converter; self.format = format; self.continuation = continuation
        }
        nonisolated func tap() -> AVAudioNodeTapBlock {
            { [self] input, _ in
                let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate)) + 64
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
                var consumed = false, error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if consumed { state.pointee = .noDataNow; return nil }
                    consumed = true; state.pointee = .haveData; return input
                }
                guard status != .error, error == nil else { continuation.finish(throwing: LiveVoiceError.audioUnavailable); return }
                guard output.frameLength > 0, let bytes = output.int16ChannelData?[0] else { return }
                let chunk = CodexVoiceAudioChunk(data: Data(bytes: bytes, count: Int(output.frameLength) * 2))
                if case .dropped = continuation.yield(chunk) { continuation.finish(throwing: LiveVoiceError.timedOut) }
            }
        }
        func finish() { continuation.finish() }
    }
}
