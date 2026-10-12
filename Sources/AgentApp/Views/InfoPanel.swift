import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var computerPresented = false
    @State private var tab = PanelTab.overview
    @State private var showingRoutineEditor = false

    private enum PanelTab: String, CaseIterable { case overview = "Overview", routines = "Routines", media = "Media", computer = "Computer", members = "Members" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }.buttonStyle(.plain).help("Bot settings")
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close")
            }.padding(.horizontal, 14).frame(height: 54)
            Divider().opacity(0.5)
            HStack(spacing: 3) { ForEach(PanelTab.allCases, id: \.self) { item in Button(item.rawValue) { tab = item }.font(.system(size: 10, weight: tab == item ? .semibold : .regular)).buttonStyle(.plain).padding(.horizontal, 6).frame(height: 26).background(tab == item ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6)) } }.padding(8)
            Divider().opacity(0.5)
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(.background)
            .sheet(isPresented: $computerPresented) { ComputerView().frame(minWidth: 1000, minHeight: 680) }
            .sheet(isPresented: $showingRoutineEditor) { RoutineEditor(bot: bot) }
    }

    @ViewBuilder private var panelContent: some View {
        switch tab {
        case .overview:
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) { BotAvatar(bot: bot, size: 52); VStack(alignment: .leading) { Text(bot.name).font(.headline); Text(bot.title).foregroundStyle(.secondary) } }
                Text(bot.botDescription.isEmpty ? "No description yet." : bot.botDescription).foregroundStyle(.secondary)
                infoSection("Memory", text: bot.memorySummary.isEmpty ? "Memory will appear as this bot learns your preferences." : bot.memorySummary)
                VStack(alignment: .leading, spacing: 8) { Text("Skills").font(.headline); FlowLayout(items: bot.skills.isEmpty ? ["No skills configured"] : bot.skills) }
            }
        case .routines:
            VStack(alignment: .leading, spacing: 12) { HStack { Text("Routines").font(.headline); Spacer(); Button { showingRoutineEditor = true } label: { Image(systemName: "plus") } }
                ForEach(store.routines[bot.id] ?? []) { routine in RoutineRow(routine: routine) { updated in if let index = store.routines[bot.id]?.firstIndex(where: { $0.id == updated.id }) { store.routines[bot.id]?[index] = updated } } }
                if (store.routines[bot.id] ?? []).isEmpty { Text("No routines yet. Create one to run this bot on a schedule or trigger.").foregroundStyle(.secondary) }
            }
        case .media:
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) { ForEach(bot.messages.filter { [.attachment, .image].contains($0.presentation) }) { message in RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)).frame(height: 105).overlay(VStack { Image(systemName: message.presentation == .image ? "photo" : "doc").font(.title); Text(message.metadata["name"] ?? "Chat media").font(.caption).lineLimit(1) }) } }
            if !bot.messages.contains(where: { [.attachment, .image].contains($0.presentation) }) { Text("Files and images shared in this chat will appear here.").foregroundStyle(.secondary) }
        case .computer:
            VStack(spacing: 12) { ComputerView().frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10)); HStack { Button("Open") { computerPresented = true }; Spacer(); Button("Take over") { computerPresented = true }.buttonStyle(.borderedProminent) } }
        case .members:
            VStack(alignment: .leading, spacing: 12) { Text("Members").font(.headline); member("Konrad", role: "Owner"); member(bot.name, role: "Agent"); Button("Invite member") { }.disabled(true); Text("TODO: connect workspace membership to the backend.").font(.caption).foregroundStyle(.tertiary) }
        }
    }
    private func infoSection(_ title: String, text: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).lineSpacing(2) } }
    private func member(_ name: String, role: String) -> some View { HStack { Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(name); Text(role).font(.caption).foregroundStyle(.secondary) } } }
}

private struct FlowLayout: View { let items: [String]; var body: some View { VStack(alignment: .leading, spacing: 6) { ForEach(items, id: \.self) { Text($0).font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(.primary.opacity(0.06), in: Capsule()) } } } }
private struct RoutineRow: View { @State var routine: BotRoutine; let update: (BotRoutine) -> Void; var body: some View { VStack(alignment: .leading, spacing: 5) { HStack { Text(routine.name).fontWeight(.medium); Spacer(); Toggle("", isOn: $routine.isEnabled).labelsHidden().controlSize(.small).onChange(of: routine.isEnabled) { _, _ in update(routine) } }; Text(routine.schedule).font(.caption).foregroundStyle(.secondary); Text("Last run: \(routine.lastRun)").font(.caption2).foregroundStyle(.tertiary) }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9)) } }
private struct RoutineEditor: View { @EnvironmentObject var store: AppStore; @Environment(\.dismiss) var dismiss; let bot: Bot; @State var name = ""; @State var schedule = "Every weekday at 9:00"; var body: some View { VStack(alignment: .leading, spacing: 16) { Text("New routine").font(.title2.bold()); TextField("Name", text: $name); TextField("Schedule or trigger", text: $schedule); Text("TODO: backend scheduling is mocked locally.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { store.routines[bot.id, default: []].append(.init(name: name, schedule: schedule)); dismiss() }.buttonStyle(.borderedProminent).disabled(name.isEmpty) } }.padding(22).frame(width: 420) } }
