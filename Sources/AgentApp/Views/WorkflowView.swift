import SwiftUI

/// P38 D: a group's workflows inside its chat: the plan to approve, each task with its agent, state, result and the
/// way past a task that did not finish (Refresh, Retry unsent, reassign), the token allowance and the controls.
/// P38 E: handoffs the agents asked for (where a task came from, review rounds and verdicts, the history) and the user's
/// "Accept review with noted limitations" when a review still has open findings.
struct WorkflowView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var group: GroupChat

    var body: some View {
        ForEach(store.workflows(in: group)) { workflow in WorkflowCard(workflow: workflow).id("workflow-\(workflow.id)") }
    }
}

struct WorkflowCard: View {
    @EnvironmentObject private var store: AppStore
    let workflow: Workflow
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(workflow.request).font(.callout).textSelection(.enabled)
                Text(budgetLine).font(.caption).foregroundStyle(.secondary)
                if workflow.state == .paused {
                    Stepper("Token allowance: \(workflow.budget.tokenLimit.formatted())", value: Binding(get: { workflow.budget.tokenLimit }, set: { store.setWorkflowAllowance(workflow.id, tokens: $0) }),
                            in: 8_000...1_000_000, step: 8_000).font(.caption)
                }
                if let error = workflow.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if workflow.state == .planning { Text("\(name(workflow.coordinatorID)) is planning. Nothing runs until you approve the plan.").font(.caption).foregroundStyle(.secondary) }
                ForEach(workflow.tasks) { task in WorkflowTaskRow(workflow: workflow, task: task) }
                if let operations = workflow.operations, !operations.isEmpty {
                    DisclosureGroup("Handoff and result history (\(operations.count))") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(operations) { operation in
                                Text("\(operation.taskID) · \(Self.label(operation.action)) · \(operation.message)").textSelection(.enabled)
                            }
                        }.padding(.leading, 4)
                    }.font(.caption)
                }
                if workflow.isTeam { TeamControlsView(workflow: workflow) }
                else if workflow.state == .paused {
                    Button("Allow in-scope help and reviews") { store.authorizeTeamWorkflow(workflow.id) }.font(.caption)
                }
                HStack {
                    if workflow.state == .paused, !workflow.awaitsUserAcceptance, !workflow.tasks.isEmpty, !workflow.tasks.contains(where: { $0.state == .blocked }) {
                        Button(workflow.tasks.allSatisfy { $0.state == .queued } ? "Approve plan and run" : "Resume") { store.resumeWorkflow(workflow.id) }
                            .buttonStyle(NeutralPrimaryButtonStyle())
                    }
                    if workflow.state == .running { Button("Pause new work") { store.pauseWorkflow(workflow.id) } }
                    if !workflow.isFinished { Button("Request Stop for workflow", role: .destructive) { store.pauseWorkflow(workflow.id, cancel: true) } }
                }.font(.caption)
            }.padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text(workflow.isTeam ? "Team work" : "Workflow").font(.callout.weight(.semibold))
                Text(workflow.stateLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Coordinator: \(name(workflow.coordinatorID))").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 28).padding(.vertical, 6)
    }

    private var budgetLine: String {
        "Tokens: \(workflow.budget.spent.formatted()) used · \(workflow.budget.reserved.formatted()) reserved · \(workflow.budget.tokenLimit.formatted()) allowed (estimated where the server reports none)"
    }
    private func name(_ id: UUID) -> String { store.bots.first { $0.id == id }?.name ?? "Removed agent" }

    static func label(_ action: WorkflowOperation.Action) -> String {
        switch action {
        case .assign: "Assigned work"
        case .requestHelp: "Asked for help"
        case .requestReview: "Asked for review"
        case .reportResult: "Reported a result"
        }
    }
}

private struct WorkflowTaskRow: View {
    @EnvironmentObject private var store: AppStore
    let workflow: Workflow
    let task: WorkflowTask
    @State private var expanded: Bool
    @State private var instruction = ""

    init(workflow: Workflow, task: WorkflowTask) { self.workflow = workflow; self.task = task
        _expanded = State(initialValue: task.state == .blocked || task.state == .awaitingUserAcceptance)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.instructions).textSelection(.enabled)
                Button("Open task thread") { store.openWorkflowTask(task) }
                if let delivery = task.delivery {
                    Text(delivery.state.label).foregroundStyle(.secondary)
                    DisclosureGroup("Delivery details") {
                        Text("Operation: " + delivery.envelope.operationID).textSelection(.enabled)
                        Text("Session: " + delivery.sessionID).textSelection(.enabled)
                        Text("Run: " + (delivery.runID ?? "Not reported by backend")).textSelection(.enabled)
                        Text("Executing model: not attested by this API").foregroundStyle(.secondary)
                    }.font(.caption2)
                    if task.completionConfirmed == true {
                        Text(task.verifiedByUser == true ? "Acceptance checks confirmed by you" : "Remote reply finished; acceptance checks not verified")
                        if task.verifiedByUser != true && task.state != .awaitingUserAcceptance { Button("I verified the acceptance checks") { store.confirmTeamEvidence(workflow.id, taskID: task.id) } }
                    }
                    ForEach(task.evidence ?? [], id: \.source) { evidence in Text(evidence.source + ": " + evidence.observation).textSelection(.enabled) }
                }
                if workflow.isTeam && task.state == .queued {
                    HStack {
                        TextField("Instructions for this task", text: $instruction)
                        Button("Add") { store.interveneInTeamTask(workflow.id, taskID: task.id, text: instruction); instruction = "" }.disabled(instruction.isEmpty)
                    }
                }
                Text("Expected: " + task.expectedOutput).foregroundStyle(.secondary)
                if let parent = task.parentTaskID { Text("From: " + parent).foregroundStyle(.secondary) }
                if let round = task.reviewRound {
                    Text("Review round \(round) of \(workflow.reviewLimit) · \(task.state == .awaitingUserAcceptance ? task.stateLabel : task.reviewVerdict.map { $0 == .accepted ? "Accepted" : "Needs revision" } ?? "Awaiting verdict")").foregroundStyle(.secondary)
                }
                if !task.dependencies.isEmpty { Text("After: " + task.dependencies.joined(separator: ", ")).foregroundStyle(.secondary) }
                if let result = task.result { Text(result).lineLimit(8).textSelection(.enabled).padding(.top, 2) }
                if let error = task.error { Text(error).foregroundStyle(.red) }
                if task.reviewAcceptedByUser == true { Text("You accepted this review with its noted limitations.").foregroundStyle(.secondary) }
                HStack {
                    if store.canAcceptWorkflowReview(workflow, task: task) {
                        Button("Accept review with noted limitations") { store.acceptWorkflowReview(workflow.id, taskID: task.id) }
                    }
                    if task.state == .blocked, !store.canAcceptWorkflowReview(workflow, task: task) { Button("Refresh from server") { Task { await store.refreshWorkflowTask(workflow.id, taskID: task.id) } } }
                    if store.canReassignWorkflowTask(workflow, task: task) {
                        if task.state == .blocked { Button("Send again") { store.reassignWorkflowTask(workflow.id, taskID: task.id, botID: task.botID) } }
                        Picker("Agent", selection: Binding(get: { task.botID }, set: { store.reassignWorkflowTask(workflow.id, taskID: task.id, botID: $0) })) {
                            ForEach(store.workflowMembers(workflow)) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 220)
                    }
                }
            }.font(.caption).padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(task.state == .blocked ? Color.red : Color.secondary).frame(width: 14)
                Text(task.id).font(.caption.weight(.medium))
                Text("· \(store.bots.first { $0.id == task.botID }?.name ?? "Removed agent")\(task.role == .coding ? " · coding" : "")\(task.reviewTargetID != nil ? " · review" : "")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(task.stateLabel).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch task.state {
        case .queued: "circle"
        case .running: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .awaitingUserAcceptance: "clock"
        }
    }
}

/// P38 D: "Plan a workflow": the request and the member who plans it. The plan comes back for approval.
struct WorkflowStartSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: GroupChat
    @State var request = ""
    @State var coordinatorID: UUID?

    var body: some View {
        let members = store.members(of: group)
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan a workflow").font(.headline)
            Text("A coordinator splits the request into tasks for the members. You review the plan before anything runs; tasks then run one after another, each in its own thread, and the final answer is posted here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $request).font(.body).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(AppColor.separator, lineWidth: 0.5))
            if members.isEmpty { Text("Add agents to this group first.").font(.caption).foregroundStyle(.secondary) }
            else {
                Picker("Coordinator", selection: Binding(get: { coordinatorID ?? members[0].id }, set: { coordinatorID = $0 })) {
                    ForEach(members) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 320)
            }
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Plan") {
                    guard let coordinator = members.first(where: { $0.id == (coordinatorID ?? members.first?.id) }) else { return }
                    if store.startWorkflow(text: request, group: group, coordinator: coordinator) { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(NeutralPrimaryButtonStyle()).disabled(reason != nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 480)
    }

    private var reason: String? {
        if store.members(of: group).isEmpty { return nil }
        if store.workflows(in: group).contains(where: \.isActive) { return "This group already has a workflow running. Pause or finish it first." }
        if let full = store.turnCapacityProblem(for: []) { return full }
        return nil
    }
}
