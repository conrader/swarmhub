import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var computerPresented = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Agent info").font(.headline); Spacer(); Button { store.editingBot = bot } label: { Image(systemName: "gearshape") }; Button { withAnimation { store.showInfo = false } } label: { Image(systemName: "xmark") } }.buttonStyle(.plain).padding(16)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Button { computerPresented = true } label: { computerPreview }.buttonStyle(.plain)
                    sectionTitle("Routines", icon: "clock.arrow.circlepath")
                    VStack(spacing: 0) { ForEach($bot.routines) { $routine in HStack { VStack(alignment: .leading, spacing: 3) { Text(routine.name).font(.callout.weight(.medium)); Text(routine.schedule).font(.caption).foregroundStyle(.secondary) }; Spacer(); Toggle("", isOn: $routine.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.mini) }.padding(.vertical, 9); if routine.id != bot.routines.last?.id { Divider() } } }
                    sectionTitle("Sub-agents", icon: "person.2")
                    VStack(spacing: 12) { ForEach(store.subAgents) { task in HStack(alignment: .top, spacing: 9) { statusIcon(task.status); VStack(alignment: .leading, spacing: 2) { Text(task.title).font(.callout.weight(.medium)); Text(task.detail).font(.caption).foregroundStyle(.secondary) }; Spacer() } } }
                }.padding(16)
            }
        }.frame(minWidth: 270, idealWidth: 300, maxWidth: 330).background(.ultraThinMaterial).sheet(isPresented: $computerPresented) { ComputerView().frame(minWidth: 900, minHeight: 620) }
    }
    private var computerPreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack { RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color.indigo.opacity(0.16), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)); VStack(spacing: 10) { Image(systemName: "desktopcomputer").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor); Text("Computer preview").font(.callout.weight(.medium)); Text("noVNC is not connected").font(.caption).foregroundStyle(.secondary) } }
                .frame(height: 154).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary)).overlay(alignment: .topLeading) { HStack(spacing: 5) { Circle().fill(.red.opacity(0.7)); Circle().fill(.yellow.opacity(0.7)); Circle().fill(.green.opacity(0.7)) }.frame(width: 8, height: 8).padding(12) }
            HStack { Circle().fill(.orange).frame(width: 7, height: 7); Text("Computer offline").font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func sectionTitle(_ title: String, icon: String) -> some View { HStack { Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.6); Spacer(); Button { } label: { Image(systemName: "plus").font(.caption) }.buttonStyle(.plain).foregroundStyle(.secondary) } }
    private func statusIcon(_ status: SubAgentStatus) -> some View { Image(systemName: status == .completed ? "checkmark.circle.fill" : status == .running ? "circle.dotted.circle.fill" : status == .failed ? "xmark.circle.fill" : "clock.fill").foregroundStyle(status == .completed ? .green : status == .failed ? .red : Color.accentColor).font(.callout) }
}
