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
                Text("\(request.launchModel ?? "Model unreported") · \(address)/\(String(created))").font(.caption)
            }
            Text(HerdrClient.Approval.visible(request.cwd)).font(.caption).textSelection(.enabled)
            ScrollView {
                Text(HerdrClient.Approval.visible(request.arguments)).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            if let reviewer = request.reviewer {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude \(reviewer.model.capitalized) review").font(.subheadline.bold())
                    Text(reviewer.assessment.map(HerdrClient.Approval.visible) ?? "Reviewing command…")
                        .font(.callout).textSelection(.enabled)
                }.accessibilityIdentifier("approval.commandReview")
            }
            HStack {
                Button("Allow once") { respond(.approve) }
                    .keyboardShortcut(keyboardDecisions ? KeyboardShortcut(.return, modifiers: .command) : nil)
                if request.canRememberCommand == true {
                    Button("Always allow here") { respond(.rememberCommand) }
                        .help("Save this exact command for this bot and folder. Revoke it in Details → Approvals.")
                }
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

struct HerdrCommandRules: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.workspaceApprovals) private var inboxes
    let botID: UUID
    let server: HerdrServer
    @State private var rules: [HerdrClient.CommandRule] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !rules.isEmpty { Text("Saved command rules").font(.headline) }
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    Text(HerdrClient.Approval.visible(rule.command)).font(.body.monospaced()).textSelection(.enabled)
                    Text(rule.provider + " · " + HerdrClient.Approval.visible(rule.cwd)).font(.caption)
                    Button("Revoke") {
                        Task {
                            do {
                                try await store.herdrClient(for: server).revokeCommandRule(rule.id)
                                rules.removeAll { $0.id == rule.id }
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(AppColor.caution) }
        }
        .task(id: inboxes[server.id]?.requests) {
            do {
                let result = try await store.herdrClient(for: server).commandRules(for: botID)
                guard !Task.isCancelled else { return }
                rules = result
                error = nil
            } catch HerdrClient.Failure.http(404, _) { rules = [] }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
