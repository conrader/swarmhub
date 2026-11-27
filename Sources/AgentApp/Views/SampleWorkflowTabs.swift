import SwiftUI

/// Navigation shared by the sample chats, their helpers, and the approval inbox.
struct SampleWorkflowTabs: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var bot: Bot
    @Binding var previewColorScheme: ColorScheme?

    private var selectedStory: SampleWalkthrough? {
        if store.showOnlyAttention { return nil }
        if store.openHerdrHelper?.botID == bot.id { return .team }
        return bot.sampleWalkthrough?.story
    }

    var body: some View {
        HStack(spacing: 12) {
            LibraryFlow(spacing: 4) {
                storyButton(.release)
                tab("Inbox & approvals", selected: store.showOnlyAttention) { store.showOnlyAttention = true }
                storyButton(.checks)
                storyButton(.brief)
                storyButton(.team)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sample workflows")
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                tab("Dark", selected: colorScheme == .dark) { previewColorScheme = .dark }
                tab("Light", selected: colorScheme == .light) { previewColorScheme = .light }
            }
            .padding(2)
            .background(AppColor.panel, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview appearance")
        }
    }

    private func storyButton(_ story: SampleWalkthrough) -> some View {
        tab(story.title, selected: selectedStory == story) { store.showSampleStory(story) }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(selected ? AppColor.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
