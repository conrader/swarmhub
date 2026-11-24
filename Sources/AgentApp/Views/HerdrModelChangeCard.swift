import SwiftUI

/// Above the composer of a server's main bot: the change of the bots' agent program and model that was last applied
/// for it, with Undo, "Start fresh agents" and Done; and each change its newest reply asks the person about, with
/// Apply and Not now. Nothing of those is changed until Apply is pressed (`AppStore+HerdrModels.swift`).
struct HerdrModelChangeCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var manager: Bot
    @State private var applying: Set<String> = []
    /// Why Apply did not apply, by request.
    @State private var refused: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pending = store.pendingHerdrModels(for: manager), records = store.herdrModelRecords(by: manager, on: store.herdrServer(for: manager))
        // A card that arrives or leaves does so gently, so the message box does not jump.
        Group { card(pending, records) }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pending.count + records.count)
    }

    @ViewBuilder private func card(_ pending: [AppStore.PendingHerdrModel], _ records: [AppStore.HerdrModelRecord]) -> some View {
        if !pending.isEmpty || !records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(records) { record in
                    HerdrModelRecordRow(record: record, title: HerdrModelRecordRow.title(record, by: manager.name))
                }
                if !pending.isEmpty {
                    Text("\(manager.name) suggests a change of what bots run on").font(.caption.weight(.semibold)).foregroundStyle(manager.tintInk)
                    ForEach(pending) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.secondary).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.request.who) → \(item.request.what)").font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                if let why = refused[item.id] {
                                    Text(why).font(.caption).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(HerdrModelRecordRow.caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if applying.contains(item.id) { ProgressView().controlSize(.small) }
                            else {
                                Button("Not now") { store.dismissHerdrModel(item) }
                                Button("Apply") { apply(item) }.buttonStyle(.appleProminent)
                            }
                        }
                    }
                }
            }.chatCard(tint: manager.colours).transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func apply(_ item: AppStore.PendingHerdrModel) {
        applying.insert(item.id)
        Task {
            refused[item.id] = await store.acceptHerdrModel(item, manager: manager)?.text
            applying.remove(item.id)
        }
    }
}

/// A change that was applied, in the main bot's chat and in Settings, with its session status, Undo and Done.
struct HerdrModelRecordRow: View {
    @EnvironmentObject private var store: AppStore
    let record: AppStore.HerdrModelRecord; let title: String
    @State private var starting = false

    static let caption = "Each bot uses this choice for its next direct reply and keeps its chat history."
    static let undoCaption = "These bots use their previous model choices for their next direct replies."

    /// "Jarvis switched 23 bots to Codex · GPT-6.2 Sol"; `asker` nil for a change made in Settings.
    static func title(_ record: AppStore.HerdrModelRecord, by asker: String?) -> String {
        let count = AppStore.botCount(record.changes.count)
        if record.undo { return "\(count) \(record.changes.count == 1 ? "is" : "are") back on what \(record.changes.count == 1 ? "it" : "they") ran before" }
        return asker.map { "\($0) switched \(count) to \(record.label)" } ?? "Switched \(count) to \(record.label)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.secondary).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(record.rolloverSummary ?? (record.undo ? Self.undoCaption : Self.caption))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if starting { ProgressView().controlSize(.small) }
            else {
                if !record.undo { Button("Undo") { undo() }.help("Puts these bots back on what they ran before") }
                Button("Done") { store.doneWithHerdrModels(record) }
            }
        }
    }

    private func undo() {
        starting = true
        Task {
            await store.undoHerdrModels(record)
            starting = false
        }
    }
}
