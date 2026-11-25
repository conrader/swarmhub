import SwiftUI

/// Presents requests from the current workspace session above its chat composer.
struct HerdrChatApprovals: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let server: HerdrServer
    var group: GroupChat? = nil
    @Environment(\.workspaceApprovals) private var inboxes
    @State private var error: String?
    @State private var decided: Set<Int> = []

    var body: some View {
        let pending = store.approvals(for: bot, in: group, inboxes: inboxes)
        VStack(alignment: .leading, spacing: 6) {
            if let request = pending.first(where: { !decided.contains($0.id) }) {
                HerdrApprovalReview(request: request, server: server) {
                    decided.insert(request.id)
                }.id(request.id).chatCard(tint: bot.colours)
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
}

struct HerdrApprovalReview: View {
    @EnvironmentObject private var store: AppStore
    let request: HerdrClient.Approval
    let server: HerdrServer
    var keyboardDecisions = false
    let didDecide: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
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
                Button("Allow once") { respond(.approve) }
                    .keyboardShortcut(keyboardDecisions ? KeyboardShortcut(.return, modifiers: .command) : nil)
                Button("Deny") { respond(.deny) }
                    .keyboardShortcut(keyboardDecisions ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            }.disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(AppColor.caution) }
        }
    }

    private func respond(_ decision: HerdrClient.Decision) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await store.herdrClient(for: server).decide(request, decision)
                didDecide()
            } catch { self.error = error.localizedDescription }
        }
    }
}
