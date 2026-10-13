import SwiftUI

/// The Overview "Model" section: the chat's current model and a per-chat picker grouped by the box's suppliers.
/// Static (no animations); every decision comes from `ModelPickerModel`.
struct ModelSectionView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache

    private var info: BotServerInfo? { cache.info(for: bot.id) }

    var body: some View {
        let picker = store.modelPicker(for: bot)
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Model").font(.headline); Spacer(); refreshButton }
            current(picker)
            if picker.showsMenu { menu(picker) }
            if let caption = picker.caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(picker.notes.enumerated()), id: \.offset) { _, note in noteView(note) }
            if let error = info?.modelError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let footer = picker.footer { Text(footer).font(.caption2).foregroundStyle(.tertiary) }
            ModelRolesReadout(bot: bot, cache: cache)
        }
    }

    @ViewBuilder private func current(_ picker: ModelPickerModel) -> some View {
        if let model = picker.currentModel {
            VStack(alignment: .leading, spacing: 2) {
                Text(model).font(.callout.weight(.medium)).textSelection(.enabled)
                if let caption = picker.currentCaption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(picker.currentAccessibilityLabel ?? model)
        } else if info?.isRefreshing ?? true {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("The server did not report a model.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func menu(_ picker: ModelPickerModel) -> some View {
        Menu {
            ForEach(picker.groups) { group in
                if group.usesSubmenu {
                    Menu(group.title) { items(group) }
                } else {
                    Section(group.title) { items(group) }
                }
            }
        } label: { Text(picker.isSwitching ? "Switching…" : ModelPickerModel.buttonTitle) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(ModelPickerModel.buttonHelp)
            .disabled(picker.groups.isEmpty)
    }

    @ViewBuilder private func items(_ group: ModelPickerModel.Group) -> some View {
        if let note = group.note { Text(note) }
        ForEach(group.items) { item in
            Button {
                Task { await store.switchModel(for: bot, provider: item.supplierSlug, model: item.model) }
            } label: {
                let title = item.detail.map { Text(item.model) + Text("  \($0)").foregroundStyle(.secondary) } ?? Text(item.model)
                if item.isChecked { Label { title } icon: { Image(systemName: "checkmark") } } else { title }
            }
            .disabled(!item.isEnabled)
            .accessibilityLabel(item.accessibilityLabel)
        }
    }

    private func noteView(_ note: ModelPickerModel.Note) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(note.text).font(.caption).foregroundStyle(note.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            if note.offersRetry { Spacer(); Button("Retry") { Task { await store.loadServerInfo(for: bot, force: true) } }.controlSize(.small) }
        }
    }

    private var refreshButton: some View {
        Button { Task { await store.loadServerInfo(for: bot, force: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }
            .buttonStyle(.plain).help("Reload skills, tools and the box's models").disabled(info?.isRefreshing ?? false)
    }
}
