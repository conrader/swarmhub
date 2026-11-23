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
        let pending = store.pendingHerdrModels(for: manager), record = store.herdrModelRecord(by: manager, on: store.herdrServer(for: manager))
        // A card that arrives or leaves does so gently, so the message box does not jump.
        Group { card(pending, record) }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pending.count + (record == nil ? 0 : 1))
    }

    @ViewBuilder private func card(_ pending: [AppStore.PendingHerdrModel], _ record: AppStore.HerdrModelRecord?) -> some View {
        if !pending.isEmpty || record != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let record {
                    HerdrModelRecordRow(record: record, title: "\(manager.name) switched \(AppStore.botCount(record.changes.count)) to \(record.label)")
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

/// A change that was applied, in the main bot's chat and in Settings: what it was, and Undo, "Start fresh agents"
/// and Done. A bot that was answering when fresh agents were started is offered again as "Start the rest fresh".
struct HerdrModelRecordRow: View {
    @EnvironmentObject private var store: AppStore
    let record: AppStore.HerdrModelRecord; let title: String
    @State private var starting = false

    static let caption = "This changes the setting. A bot whose agent is running keeps its model until that agent is started fresh."
    static let freshHelp = "Ends the running agents of these bots, except one that is answering. Each starts on the new model with its next message, and reads its conversation so far first."

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.secondary).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(record.note.isEmpty ? Self.caption : record.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if starting { ProgressView().controlSize(.small) }
            else {
                Button("Undo") { store.undoHerdrModels(record) }.help("Puts these bots back on what they ran before")
                if record.notFresh > 0 {
                    Button(record.fresh.isEmpty ? "Start fresh agents" : "Start the rest fresh") { fresh() }.help(Self.freshHelp)
                }
                Button("Done") { store.doneWithHerdrModels(record) }
            }
        }
    }

    private func fresh() {
        starting = true
        Task { await store.startFreshHerdrAgents(record); starting = false }
    }
}
