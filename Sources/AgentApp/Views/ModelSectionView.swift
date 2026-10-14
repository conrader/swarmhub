import SwiftUI

/// The Overview "Model" section (P21b item 1): "Model: <name> · <supplier>" and a plain picker of this agent's own
/// models on top; the source, supplier details, notes, roles and "Last turn ran on" fold under Advanced
/// (`ModelSectionAdvanced`). Static (no animations); every decision comes from `ModelPickerModel` and `ModelSimpleLine`,
/// and a pick goes through the same `switchModel` as before.
struct ModelSectionView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache

    private var info: BotServerInfo? { cache.info(for: bot.id) }
    /// A non-Hermes agent shows only the heading, its catalog notes and where the list comes from.
    private var isHermes: Bool { bot.backend == .hermes }

    var body: some View {
        let picker = store.modelPicker(for: bot)
        let simple = ModelSimpleLine(picker: picker, isRefreshing: info?.isRefreshing ?? true, error: info?.modelError)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(simple.line).font(.headline).textSelection(.enabled).accessibilityLabel(picker.currentAccessibilityLabel ?? simple.line)
                Spacer(); if isHermes { refreshButton }
            }
            if simple.showsPicker { menu(picker, title: simple.pickerTitle) }
            if let status = simple.status {
                Text(status).font(.caption).foregroundStyle(simple.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            AdvancedFold { ModelSectionAdvanced(bot: bot, cache: cache, picker: picker) }
        }
    }

    private func menu(_ picker: ModelPickerModel, title: String) -> some View {
        Menu {
            ForEach(picker.groups) { group in
                if group.usesSubmenu {
                    Menu(group.title) { items(group) }
                } else {
                    Section(group.title) { items(group) }
                }
            }
        } label: { Text(title) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(picker.unpinHelp ?? "")
            .disabled(picker.groups.isEmpty)
    }

    @ViewBuilder private func items(_ group: ModelPickerModel.Group) -> some View {
        if let note = group.note { Text(note) }
        ForEach(group.items) { item in
            Button {
                Task { await store.switchModel(for: bot, provider: item.supplierSlug, model: item.model) }
            } label: {
                let title = item.detail.map { Text(item.model) + Text(verbatim: "  \($0)").foregroundStyle(.secondary) } ?? Text(item.model)
                if item.isChecked { Label { title } icon: { Image(systemName: "checkmark") } } else { title }
            }
            .disabled(!item.isEnabled)
            .accessibilityLabel(item.accessibilityLabel)
        }
    }

    private var refreshButton: some View {
        Button { Task { await store.loadServerInfo(for: bot, force: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
            .buttonStyle(.plain).help(InspectorCopy.reloadModels).disabled(info?.isRefreshing ?? false)
    }
}
