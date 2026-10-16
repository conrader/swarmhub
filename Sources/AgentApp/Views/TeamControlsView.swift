import SwiftUI
import SwarmHubCoordination

struct TeamControlsView: View {
    @EnvironmentObject private var store: AppStore
    let workflow: Workflow
    @State private var intervention = ""
    @State private var showSettings = false

    var body: some View {
        if let team = workflow.coordination {
            VStack(alignment: .leading, spacing: 6) {
                Text("Coordination runs while SwarmHub is available. Unsent work waits here.").foregroundStyle(.secondary)
                Text("Permission v\(team.policy.version) · \(team.policy.revokedAt == nil ? "Task routing only" : "Revoked") · \(Int(team.activeSeconds))s active")
                if store.turns.pathDown { Text("Waiting for connection").foregroundStyle(.secondary) }
                HStack {
                    if workflow.state == .paused { Button("Limits and reporting") { showSettings = true } }
                    Button("Check remote work") { Task { await store.recoverTeams() } }
                    if !workflow.isFinished {
                        Menu("Delegation") {
                            if workflow.state == .paused { Button("Authorize current team") { store.authorizeTeamWorkflow(workflow.id) } }
                            Button("Revoke delegation") { store.revokeTeamPolicy(workflow.id) }
                            Button("Cancel queued work") { store.cancelQueuedTeamWork(workflow.id) }
                        }.fixedSize()
                    }
                }

                if !workflow.isFinished {
                    HStack {
                        TextField("Instructions for the next tasks", text: $intervention)
                        Button("Add") { store.interveneInTeam(workflow.id, text: intervention); intervention = "" }.disabled(intervention.isEmpty)
                    }
                    Text("For a task already running, open its thread to steer or request Stop.").foregroundStyle(.secondary)
                }
            }.font(.caption)
            .sheet(isPresented: $showSettings) { TeamSettingsView(workflowID: workflow.id) }
        }
    }
}

private struct TeamSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let workflowID: UUID
    @State private var appTool = ""
    @State private var appAccount = ""
    @State private var reviewerID: UUID?
    @State private var timeZone = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let workflow = store.workflows[workflowID], let team = workflow.coordination {
                Text("Team limits and reporting").font(.headline)
                Stepper("Tasks: \(team.limits.tasks)", value: binding(\.limits.tasks, team.limits.tasks), in: max(2, workflow.tasks.count)...100)
                Stepper("Review rounds: \(team.limits.reviewRounds)", value: binding(\.limits.reviewRounds, team.limits.reviewRounds), in: 1...5)
                Stepper("Handoff depth: \(team.limits.handoffDepth)", value: binding(\.limits.handoffDepth, team.limits.handoffDepth), in: 1...10)
                Stepper("Independent tasks at once: \(team.limits.parallelTasks)", value: binding(\.limits.parallelTasks, team.limits.parallelTasks), in: 1...4)
                Stepper("Active minutes: \(Int(team.limits.activeSeconds / 60))", value: binding(\.limits.activeSeconds, team.limits.activeSeconds), in: 60...86400, step: 60)
                Toggle("Require my verification of acceptance checks", isOn: binding(\.requiresEvidence, team.requiresEvidence))
                Toggle("Notify me about blockers", isOn: binding(\.reporting.notifyBlockers, team.reporting.notifyBlockers))
                Toggle("Notify me about the final result", isOn: binding(\.reporting.notifyResults, team.reporting.notifyResults))
                Toggle("Quiet hours (22:00–08:00)", isOn: Binding(get: { team.reporting.quietStartMinute != nil }, set: { enabled in
                    store.editTeam(workflowID) { $0.reporting.quietStartMinute = enabled ? 22 * 60 : nil; $0.reporting.quietEndMinute = enabled ? 8 * 60 : nil }
                }))
                HStack {
                    TextField("Timezone (blank follows this device)", text: $timeZone)
                    Button("Apply timezone") { store.editTeam(workflowID) { $0.reporting.timeZoneID = timeZone.isEmpty ? nil : timeZone } }
                }
                Toggle("Delegation expires", isOn: Binding(get: { team.policy.expiresAt != nil }, set: { enabled in
                    store.editTeam(workflowID) { $0.policy.expiresAt = enabled ? store.now().addingTimeInterval(86400) : nil }
                }))
                if let expiry = team.policy.expiresAt {
                    DatePicker("Until", selection: Binding(get: { expiry }, set: { date in store.editTeam(workflowID) { $0.policy.expiresAt = date } }))
                }
                DisclosureGroup("Delegate a connected-app review") {
                    TextField("Exact tool identifier", text: $appTool)
                    TextField("Exact connected account ID", text: $appAccount)
                    Picker("Reviewer", selection: $reviewerID) {
                        Text("Choose a reviewer").tag(nil as UUID?)
                        ForEach(store.workflowMembers(workflow)) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("The reviewer decides each exact set of arguments. Changed actions receive a fresh review. Backend approvals keep their own rules.").font(.caption)
                    Button("Authorize this scope") {
                        guard let reviewer = store.bots.first(where: { $0.id == reviewerID }) else { return }
                        store.editTeam(workflowID) { team in
                            team.appReviews = (team.appReviews ?? []) + [.init(tool: appTool, account: appAccount, reviewer: store.teamIdentity(reviewer))]
                        }
                        appTool = ""; appAccount = ""
                    }.disabled(appTool.isEmpty || appAccount.isEmpty || reviewerID == nil)
                    ForEach(team.appReviews ?? [], id: \.tool) { scope in Text(scope.tool + " · " + scope.account).font(.caption) }
                }
                Text("Results always stay in the originating chat and coordinator's task thread. Quiet hours silence notifications. These permissions do not change backend or connected-app approvals.").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() } }
            }
        }.padding(20).frame(width: 480).background(AppColor.chat)
            .onAppear { timeZone = store.workflows[workflowID]?.coordination?.reporting.timeZoneID ?? "" }
    }
    private func binding<T>(_ path: WritableKeyPath<TeamCoordination, T>, _ value: T) -> Binding<T> {
        Binding(get: { store.workflows[workflowID]?.coordination?[keyPath: path] ?? value }, set: { new in store.editTeam(workflowID) { $0[keyPath: path] = new } })
    }
}

struct TeamWorkView: View {
    @EnvironmentObject private var store: AppStore
    let conversationID: UUID
    var body: some View {
        ForEach(store.workflows.values.filter { $0.groupID == conversationID && $0.isTeam }.sorted { $0.createdAt < $1.createdAt }) { workflow in
            WorkflowCard(workflow: workflow)
        }
    }
}
