import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    let isStreaming: Bool
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextEditor(text: $text)
                .font(.body).scrollContentBackground(.hidden).frame(minHeight: 24, maxHeight: 120)
                .padding(8).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send(); return .handled
                }
            Button(action: isStreaming ? stop : send) {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            .disabled(!isStreaming && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(12)
    }
}
