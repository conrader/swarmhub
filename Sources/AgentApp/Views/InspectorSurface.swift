import SwiftUI

/// The backing for cards and selected rows in a bot's Details panel.
struct InspectorSurface: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape.fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                if selected { shape.fill(.tint.opacity(0.10)) }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.primary, lineWidth: selected ? 2 : 1)
                } else if selected {
                    shape.strokeBorder(.tint.opacity(0.65), lineWidth: 1)
                } else {
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    func inspectorCard(padding: CGFloat = 12, selected: Bool = false) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { InspectorSurface(selected: selected) }
    }

    /// Routines and Skills also appear in windows with the app's regular cards.
    @ViewBuilder func appleCard(padding: CGFloat, inInspector: Bool) -> some View {
        if inInspector { inspectorCard(padding: padding) }
        else { appleCard(padding: padding) }
    }
}
