import SwiftUI

struct HerdrActiveHelpersSection: View {
    @EnvironmentObject private var store: AppStore

    @State private var details: HerdrHelperOverview.Row?

    var body: some View {
        let overview = store.herdrHelperOverview
        if overview.hasBots {
            VStack(alignment: .leading, spacing: 8) {
                Text("Helpers and detached workers").font(.headline).accessibilityAddTraits(.isHeader)
                    .help("Workspace helpers and detached sb-codejob workers reported for your bots.")
                ForEach(overview.rows) { row in
                    ActiveHelperRow(bot: row.bot, groupName: row.groupName, helper: row.helper) { details = row }
                }
                ForEach(overview.codejobs) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Label("\(row.bot.name) · \(row.job.description)", systemImage: "terminal")
                            .font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text("sb-codejob · \(row.id.host) · \(row.id.job.prefix(8))")
                    }.inspectorCard(padding: 8)
                }
                if overview.confirmedEmpty { Text(overview.disconnected.isEmpty ? "No active helpers or detached workers." : "No active helpers or detached workers on connected workspaces.") }
                ForEach(overview.unattributed, id: \.server.id) { item in
                    Text("Live helpers in other sessions on \(item.server.name): \(item.count)")
                }
                ForEach(overview.disconnected) { server in Text("\(server.name) is disconnected.") }
                ForEach(overview.unavailableCodejobHosts.indices, id: \.self) { index in
                    Text("Detached activity incomplete on \(overview.unavailableCodejobHosts[index]).")
                }
                ForEach(overview.checking) { server in Text("Checking \(server.name)…") }
                ForEach(overview.unavailable) { server in Text("Couldn’t read all coding activity on \(server.name).") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("overview.activeHelpers")
            .sheet(item: $details) { row in
                HerdrHelperView(bot: row.bot, selection: row.id, helper: row.helper,
                                core: store.herdrHelpers[row.id.parent]?.core, groupName: row.groupName) { details = nil }
                    .frame(minWidth: 600, minHeight: 420)
            }
        }
    }
}

private struct ActiveHelperRow: View {
    @ObservedObject var bot: Bot
    let groupName: String?
    let helper: HerdrClient.Helper
    let openDetails: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                HerdrHelperGlyph(helper: helper)
                Text([bot.name, groupName, helper.name].compactMap { $0 }.joined(separator: " · ")).font(.callout.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Button("Details", action: openDetails).buttonStyle(.link)
                    .accessibilityLabel("Details for \(helper.name), helper of \(bot.name)\(groupName.map { " in " + $0 } ?? "")")
            }
            Text(helper.statusLine)
            if let task = helper.assignment, !task.isEmpty {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text(verbatim: task).multilineTextAlignment(.leading).lineLimit(expanded ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse task" : "Show full task")
                    .accessibilityValue(task)
            } else {
                Text("Task unavailable")
            }
        }.inspectorCard(padding: 8)
    }
}
