import SwiftUI

/// Only the open chat follows the inbox, while a turn is running or its terminal is blocked.
struct HerdrChatApprovals: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let server: HerdrServer
    @State private var pending: [HerdrClient.Approval] = []
    @State private var busy: Int?
    @State private var error: String?
    @State private var decided: Set<Int> = []

    var body: some View {
        let watching = store.isAnswering(bot) || store.herdrPrompts[bot.id] != nil || bot.goal?.state == .waiting
        VStack(alignment: .leading, spacing: 6) {
            if let request = pending.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(request.provider) requests \(HerdrClient.Approval.visible(request.tool))").font(.headline)
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
            } else { HerdrPromptCard(bot: bot) }
            if let error { Text(error).font(.caption).foregroundStyle(AppColor.caution) }
        }
        .task(id: watching) {
            guard watching, store.launchWorkEnabled else { pending = []; decided = []; error = nil; return }
            let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
            while !Task.isCancelled {
                do {
                    let rows = try await store.herdrClient(for: server).approvals(for: name)
                    try Task.checkCancellation()
                    pending = rows.filter { !decided.contains($0.id) }
                } catch {
                    if Task.isCancelled { return }
                    if !pending.isEmpty { self.error = "The approval could not be refreshed. " + error.localizedDescription }
                    pending = []
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
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
                pending.removeAll { $0.id == request.id }
            } catch { self.error = error.localizedDescription }
        }
    }
}
