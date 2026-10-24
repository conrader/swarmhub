import SwiftUI

/// autoctx1: SwarmHub asks, as a chat line with quick replies (the same chips as suggested replies), whether to restore a
/// store that was set aside. Shown over the main window while the offer stands; its outcome stays as one short line.
struct StoreRestorePrompt: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let offer = store.storeRestoreOffer {
            bubble(StoreRestoreCopy.question(offer)) {
                HStack(spacing: 6) {
                    chip(StoreRestoreCopy.restore(offer)) { store.restoreSetAsideStore() }
                    chip(StoreRestoreCopy.startFresh) { store.declineStoreRestore() }
                }.accessibilityElement(children: .contain).accessibilityLabel("Suggested replies")
            }
        } else if let note = store.storeRestoreNote {
            bubble(note) { Button("Dismiss") { store.storeRestoreNote = nil }.buttonStyle(.link).font(.callout) }
        }
    }

    private func bubble<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StoreRestoreCopy.sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 12))
            actions()
        }.padding(16).frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 48).padding(.horizontal, 16)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 6).contentShape(Capsule())
                .background(AppColor.raised, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5))
        }.buttonStyle(.plain).help("Send “\(title)”")
    }
}
