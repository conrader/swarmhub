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
    var inboxBotName: String?
    var inspect: (() -> Void)?
    var keyboardDecisions = false
    let didDecide: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let tool = HerdrClient.Approval.visible(request.tool)
            let folder = HerdrClient.Approval.visible(request.cwd)
            if let inboxBotName {
                Text("\(inboxBotName) · \(request.provider) requests \(tool)").font(.headline)
            } else {
                Text("\(request.provider) requests \(tool)").font(.headline)
            }
            if let address = request.address, let created = request.createdMs {
                Text("\(request.launchModel ?? "Model unreported") · \(address)/\(String(created))").font(.caption)
            }
            Text(folder).font(.caption).textSelection(.enabled)
            ScrollView {
                Text(inspect == nil ? HerdrClient.Approval.visible(request.arguments) : request.inboxArguments).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            if let inspect {
                Button("Inspect \(tool) request", action: inspect).controlSize(.small)
                    .help("Show full arguments and enable decision shortcuts for this request.")
            }
            if let reviewer = request.reviewer {
                VStack(alignment: .leading, spacing: 3) {
                    if inspect != nil, let name = reviewer.botName, reviewer.assessment != nil, reviewer.problem == nil {
                        Text("Reviewed by " + HerdrClient.Approval.visible(name)).font(.subheadline.bold())
                    } else {
                        Text(reviewer.title).font(.subheadline.bold())
                    }
                    Text((reviewer.problem ?? reviewer.assessment).map(HerdrClient.Approval.visible) ?? "Reviewing command…")
                        .font(.callout).textSelection(.enabled)
                }.accessibilityIdentifier("approval.commandReview")
            }
            LibraryFlow {
                Button("Allow once") { respond(.approve) }
                    .keyboardShortcut(keyboardDecisions ? KeyboardShortcut(.return, modifiers: .command) : nil)
                if request.canRememberCommandHour == true {
                    Button("Allow here for 1 hour") { respond(.rememberCommandHour) }
                        .help("Allow this exact command for this bot and folder for one hour.")
                }
                if request.canRememberCommand == true {
                    let label = inboxBotName != nil && !folder.isEmpty ? "Always allow in " + folder : "Always allow here"
                    Button { respond(.rememberCommand) } label: {
                        Text(verbatim: label).lineLimit(2).truncationMode(.middle)
                    }
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
    @State private var rules: [HerdrClient.CommandRule]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scoped rules").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            if let rules, rules.isEmpty, error == nil {
                Text("No saved command rules").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules ?? []) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    Text(HerdrClient.Approval.visible(rule.command)).font(.body.monospaced()).textSelection(.enabled)
                    Text(rule.provider + " · " + HerdrClient.Approval.visible(rule.cwd)).font(.caption)
                    if let expires = rule.expiresMs {
                        let end = Date(timeIntervalSince1970: Double(expires) / 1000)
                        Text("Until \(end.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    Button("Revoke") {
                        Task {
                            do {
                                try await store.herdrClient(for: server).revokeCommandRule(rule.id)
                                rules?.removeAll { $0.id == rule.id }
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(AppColor.caution) }
        }
        .task(id: inboxes[server.id]?.requests) {
            while !Task.isCancelled {
                do {
                    let result = try await store.herdrClient(for: server).commandRules(for: botID)
                    guard !Task.isCancelled else { return }
                    rules = result
                    error = nil
                } catch HerdrClient.Failure.http(404, _) {
                    guard !Task.isCancelled else { return }
                    rules = nil
                    error = "Update this workspace to use scoped command rules."
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                // A hook can confirm its decision after the request disappears from the inbox.
                let now = Int64(Date.now.timeIntervalSince1970 * 1000)
                let untilExpiry = rules?.compactMap(\.expiresMs).min().map { $0 - now } ?? 8_000
                do { try await Task.sleep(for: .milliseconds(max(500, min(8_000, untilExpiry)))) }
                catch { return }
            }
        }
    }
}
