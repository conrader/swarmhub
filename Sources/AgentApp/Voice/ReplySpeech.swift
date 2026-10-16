import AVFoundation
import SwiftUI

/// Speaks the actual reply in this chat. Dictation already feeds the real composer; no separate assistant or execution path.
@MainActor final class ReplySpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ReplySpeech()
    @Published private(set) var messageID: UUID?
    private let synthesizer = AVSpeechSynthesizer()
    override init() { super.init(); synthesizer.delegate = self }
    static func text(for message: ChatMessage) -> String? {
        guard message.role == .assistant, message.presentation == .text, !message.isStreaming,
              message.turnState == .finished || message.metadata["workflowResultID"] != nil else { return nil }
        let text = SwarmhubBlock.visibleText(message.finalText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    func toggle(_ message: ChatMessage) {
        if messageID == message.id { synthesizer.stopSpeaking(at: .immediate); messageID = nil; return }
        guard let text = Self.text(for: message) else { return }
        synthesizer.stopSpeaking(at: .immediate)
        messageID = message.id
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.messageID = nil
        }
    }
}

struct SpeakReplyButton: View {
    @ObservedObject private var speech = ReplySpeech.shared
    let message: ChatMessage
    var body: some View {
        if ReplySpeech.text(for: message) != nil {
            Button { speech.toggle(message) } label: {
                Image(systemName: speech.messageID == message.id ? "stop.circle" : "speaker.wave.2")
            }.help(speech.messageID == message.id ? "Stop speaking" : "Speak this reply")
        }
    }
}
