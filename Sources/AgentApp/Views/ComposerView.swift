import SwiftUI

struct ComposerView: View {
    @Binding var text: String; let isStreaming: Bool; let send: () -> Void; let stop: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                Button { } label: { Image(systemName: "paperclip").frame(width: 30, height: 30) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Attach file")
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(minHeight: 28, maxHeight: 110).padding(.vertical, 3)
                    .overlay(alignment: .topLeading) { if text.isEmpty { Text("Message your agent…").foregroundStyle(.tertiary).allowsHitTesting(false).padding(.top, 5).padding(.leading, 5) } }
                    .onKeyPress(.return, phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; send(); return .handled }
                Button { } label: { Image(systemName: "waveform").frame(width: 30, height: 30) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Voice input")
                Button(action: isStreaming ? stop : send) { Image(systemName: isStreaming ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).disabled(!isStreaming && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(9).background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary)).shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            Text("AgentApp can make mistakes. Review actions before approving.").font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
        }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 12)
    }
}
