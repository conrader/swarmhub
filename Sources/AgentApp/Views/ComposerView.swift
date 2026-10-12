import SwiftUI

struct ComposerView: View {
    @Binding var text: String; let isStreaming: Bool; let send: () -> Void
    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
                Button { } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Attach")
                TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(height: 30).padding(.vertical, 2)
                    .overlay(alignment: .topLeading) { if text.isEmpty { Text("Message " + AppConstants.name + "…").foregroundStyle(.tertiary).allowsHitTesting(false).padding(.top, 5).padding(.leading, 5) } }
                    .onKeyPress(.return, phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; send(); return .handled }
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(.primary).disabled(isStreaming || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12), lineWidth: 0.5))
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14).frame(maxWidth: 768)
    }
}
