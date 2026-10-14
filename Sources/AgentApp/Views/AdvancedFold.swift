import SwiftUI

private struct InspectorStartsAdvancedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Offscreen renders (`--render-setup`) open every right-panel "Advanced" fold; the app starts them folded.
    var inspectorStartsAdvanced: Bool {
        get { self[InspectorStartsAdvancedKey.self] }
        set { self[InspectorStartsAdvancedKey.self] = newValue }
    }
}

/// The right panel's "Advanced" fold (P21b): a quiet chevron row like the sidebar's "Hidden chats", no animation.
/// The detail is built only while open.
struct AdvancedFold<Content: View>: View {
    var startsOpen = false
    @ViewBuilder let content: () -> Content
    @Environment(\.inspectorStartsAdvanced) private var renderOpen
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? (startsOpen || renderOpen)
        VStack(alignment: .leading, spacing: 8) {
            Button { open = !isOpen } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(InspectorCopy.advanced).font(.caption.weight(.semibold))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(isOpen ? Text(verbatim: "open") : Text(verbatim: "folded"))
            if isOpen { content() }
        }.transaction { $0.animation = nil }
    }
}
