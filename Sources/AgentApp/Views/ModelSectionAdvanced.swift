import SwiftUI

/// What the Overview model section folds under Advanced (P21b item 1): where the current model came from, the supplier
/// caption and footer, the picker's notes and errors, and the P13 role lines with "Last turn ran on". Unchanged
/// behaviour; only moved out of the top of the section.
struct ModelSectionAdvanced: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache
    let picker: ModelPickerModel

    private var info: BotServerInfo? { cache.info(for: bot.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = picker.currentCaption, !caption.isEmpty { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            if let caption = picker.caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(picker.notes.enumerated()), id: \.offset) { _, note in noteView(note) }
            if let error = info?.modelError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let footer = picker.footer { Text(footer).font(.caption2).foregroundStyle(.tertiary) }
            if bot.backend == .hermes { ModelRolesReadout(bot: bot, cache: cache) }
        }
    }

    private func noteView(_ note: ModelPickerModel.Note) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(note.text).font(.caption).foregroundStyle(note.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            if note.offersRetry { Spacer(); Button("Retry") { Task { await store.loadServerInfo(for: bot, force: true) } }.controlSize(.small) }
        }
    }
}
