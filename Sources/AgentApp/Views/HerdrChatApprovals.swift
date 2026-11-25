import SwiftUI

/// Presents requests from the current workspace session and keeps decisions inside their owning chat.
struct HerdrChatApprovals: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let server: HerdrServer
    var group: GroupChat? = nil
    @Environment(\.workspaceApprovals) private var inboxes
    @State private var busy: Int?
    @State private var error: String?
    @State private var decided: Set<Int> = []

    var body: some View {
        let pending = store.approvals(for: bot, in: group, inboxes: inboxes)
        VStack(alignment: .leading, spacing: 6) {
            if let request = pending.first(where: { !decided.contains($0.id) }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(request.provider) requests \(HerdrClient.Approval.visible(request.tool))").font(.headline)
                    if let address = request.address, let created = request.createdMs {
                        Text("\(request.launchModel ?? "Model unreported") · \(address)/\(created)").font(.caption)
                    }
                    Text(HerdrClient.Approval.visible(request.cwd)).font(.caption).textSelection(.enabled)
                    ScrollView {
                        Text(HerdrClient.Approval.visible(request.arguments)).font(.body.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Allow once") { respond(request, .approve) }
                        Button("Deny") { respond(request, .deny) }
                    }.disabled(busy != nil)
                }.chatCard(tint: bot.colours)
            } else { HerdrPromptCard(bot: bot, group: group) }
            if let error { Text(error).font(.caption).foregroundStyle(AppColor.caution) }
        }
        .onChange(of: inboxes[server.id]) { previous, current in
            let names = store.approvalAgentNames(for: bot, in: group)
            if current?.unavailable == true, let previous, names.contains(where: { previous.requests[$0]?.isEmpty == false }) {
                error = "The approval could not be refreshed."
            } else if current?.unavailable == false && error == "The approval could not be refreshed." {
                error = nil
            }
        }
    }

    private func respond(_ request: HerdrClient.Approval, _ decision: HerdrClient.Decision) {
        guard busy == nil else { return }
        busy = request.id
        error = nil
        Task {
            defer { busy = nil }
            do {
                try await store.herdrClient(for: server).decide(request, decision)
                decided.insert(request.id)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
