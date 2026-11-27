import SwiftUI

/// Activity reported by the CLI for a child without a separate terminal.
struct NativeThreadOutput: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.compactWorkspaceHeight) private var compactHeight
    let server: HerdrServer
    let runtime: HerdrClient.ChildRuntime
    let core: String
    let owner: HerdrClient.AgentRef
    let thread: String
    let detail: String
    var session: HerdrClient.NativeThread? = nil
    var readable = false
    let openedParent: () -> Void
    @State private var showDetails = false
    @State private var activity: HerdrClient.ThreadActivity?
    @State private var listingStateAtRead: String?
    @State private var requestedTurn: String?
    @State private var sendingClaudeRequest = false
    @State private var promotion: Task<Void, Never>?
    @State private var readError: String?
    @State private var actionError: String?

    private var parent: (selection: HerdrHelperSelection, bot: Bot, child: HerdrClient.NativeThread)? {
        for (key, list) in store.herdrHelpers where list.core == core && list.parent == owner {
            if let child = list.nativeThreads.first(where: { $0.provider == runtime && $0.id == thread }),
               let bot = store.bots.first(where: { $0.id == key.botID }), store.herdrServer(for: bot) == server {
                let selection = HerdrHelperSelection(botID: key.botID, helperID: thread, groupRuntime: key.groupRuntime,
                                                     source: key.source, archive: key.archive, native: .init(thread: child, core: core, owner: owner, server: server))
                if key.groupRuntime == nil || store.groupOwningHelper(selection, of: bot) != nil { return (selection, bot, child) }
            }
        }
        return nil
    }

    // The sidebar and detail endpoint refresh independently. A changed listing supersedes
    // activity from the previous state, including its interruptible turn.
    private var listingState: String? { parent?.child.state }
    private var visibleState: String? {
        if let listingState, listingState != listingStateAtRead { return listingState }
        return activity?.state ?? listingState ?? session?.state
    }

    private var interruptibleTurn: String? {
        guard visibleState == "working", activity?.state == "working", listingState == listingStateAtRead else { return nil }
        return activity?.activeTurn
    }

    var body: some View {
        let observedState = listingState
        return Group {
            if let session {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if showDetails { cards(for: parent?.child ?? session) }
                            else { conversation(for: parent?.child ?? session) }
                            if !compactHeight { actionLayout }
                            errors
                        }.frame(maxWidth: showDetails ? .infinity : 720, alignment: .leading)
                            .padding(18).frame(maxWidth: .infinity)
                    }
                    if compactHeight {
                        CompactHelperFooter { actionLayout } composer: { composer }
                    } else { composer }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parent?.child.sessionDetail ?? detail).font(.caption).foregroundStyle(.secondary)
                    actionLayout
                    errors
                    if let activity {
                        TerminalTextGrid(output: HelperAssignment.transcript(activity.transcript), scrollback: true, readable: readable)
                    } else if readError == nil { ProgressView("Connecting…") }
                }
            }
        }
        .onDisappear { promotion?.cancel() }
        .task(id: observedState) {
            if server == SampleWorkspace.server {
                if let child = parent?.child {
                    activity = SampleWorkspace.activity(for: child)
                    listingStateAtRead = observedState
                }
                else { readError = "This sample session is no longer available." }
                return
            }
            while !Task.isCancelled {
                do {
                    let client = try connectedClient()
                    let snapshot = try await client.threadActivity(runtime, owner: owner, core: core, thread: thread)
                    try Task.checkCancellation()
                    activity = snapshot
                    listingStateAtRead = observedState
                    readError = nil
                    if requestedTurn != snapshot.activeTurn { requestedTurn = nil }
                } catch {
                    guard !Task.isCancelled else { return }
                    readError = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        if !showDetails, let parent, let target = store.steeringTarget(parent.selection, of: parent.bot) {
            HelperChatComposer(target: target, bot: parent.bot, draft: store.helperChatDrafts[target.id] ?? "")
                .id(target.id)
        }
    }

    @ViewBuilder private var errors: some View {
        if let error = actionError ?? readError { Text(error).font(.callout).foregroundStyle(.secondary) }
    }

    private func media(for child: HerdrClient.NativeThread, reply: String) -> HelperReplyMedia {
        .init(server: server, core: core, agent: owner,
              entry: [runtime.rawValue, thread, String(child.createdMs),
                      child.completedMs.map(String.init) ?? "", reply])
    }

    @ViewBuilder private func conversation(for child: HerdrClient.NativeThread) -> some View {
        let details = activity?.details
        let assignment = HelperAssignment.readable(details?.task ?? "") ?? HelperAssignment.readable(child.task)
        let state = visibleState ?? child.state
        helperPart("Task", detail: {
            NativeThreadDuration(thread: child, stateOverride: state, showsStatus: true)
        }) {
            Text(HerdrHelperView.assignment(assignment ?? HelperAssignment.unavailable)).textSelection(.enabled)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("helper.chatTask")
        if let parent {
            HelperGuidanceHistory(selection: parent.selection, bot: parent.bot) { instructions in
                ForEach(instructions) { message in
                    HelperChatGuidance(message: message, botName: parent.bot.name)
                }
            }
        }
        if let steps = details?.steps {
            HelperChatSteps(steps: steps, title: steps.count == 64 ? "Latest 64 steps" : "Steps (\(steps.count))", model: child.modelLine) { step in
                NativeStepRow(step: step, runtime: child.provider, command: details?.terminal?.command, sessionWorking: state == "working")
            }
        }
        let reply = visibleState == activity?.state ? details?.reply ?? child.reply : child.reply
        HelperChatReply(text: reply,
                        placeholder: state == "stopped" ? "Stopped before replying." : (state == "working" ? "No reply yet." : "No reply recorded."),
                        media: media(for: child, reply: reply), command: details?.terminal?.command, output: details?.terminal?.output)
    }

    @ViewBuilder private func cards(for child: HerdrClient.NativeThread) -> some View {
        let details = activity?.details
        let task = HelperAssignment.readable(details?.task ?? "") ?? HelperAssignment.readable(child.task) ?? HelperAssignment.unavailable
        let state = visibleState ?? child.state
        let reply = state == activity?.state ? details?.reply ?? child.reply : child.reply
        helperPart("Task", detail: {
            NativeThreadDuration(thread: child, stateOverride: state, showsStatus: true)
        }) {
            Text(HerdrHelperView.assignment(task.isEmpty ? "No task recorded." : task)).textSelection(.enabled)
        }
        if let parent { HelperGuidanceCard(selection: parent.selection, bot: parent.bot) }
        helperPart(details.map { $0.steps.count == 64 ? "Steps (latest 64)" : "Steps (\($0.steps.count))" } ?? "Steps", detail: child.modelLine) {
            if let steps = details?.steps {
                if steps.isEmpty { Text("No steps recorded.").foregroundStyle(.secondary) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    NativeStepRow(step: step, runtime: child.provider, command: details?.terminal?.command, sessionWorking: state == "working")
                }
            } else if activity == nil && readError == nil {
                ProgressView("Loading steps…").controlSize(.small)
            } else {
                Button("View recorded activity in Details") {
                    store.previewInInspector(.init(server: server, target: LiveTerminal(thread: child, owner: owner, core: core)))
                }.buttonStyle(.link)
            }
        }
        helperPart("Latest reply", detail: details?.terminal == nil ? nil : "Terminal output below") {
            if reply.isEmpty {
                switch state {
                case "working": Text("No reply yet.").foregroundStyle(.secondary)
                case "stopped": Text("Stopped before replying.").foregroundStyle(.secondary)
                default: Text("No reply recorded.").foregroundStyle(.secondary)
                }
            } else {
                NativeSessionReply(text: reply, media: media(for: child, reply: reply))
            }
            if let terminal = details?.terminal {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "$ " + terminal.command)
                        .foregroundStyle(.secondary).lineLimit(2).help(terminal.command)
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: terminal.output).fixedSize()
                    }.defaultScrollAnchor(.topLeading)
                    .frame(maxHeight: 126).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.sidebar, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .contain).accessibilityIdentifier("nativeSession.commandOutput")
            }
        }
    }

    private var actionLayout: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controls }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { controls }
        }
        .controlSize(session == nil ? .small : .large)
    }

    @ViewBuilder private var controls: some View {
        if session != nil {
            Button(showDetails ? "Show conversation" : "Session details") { showDetails.toggle() }
            if showDetails, let parent { RemoveFinishedHelperButton(selection: parent.selection, bot: parent.bot) }
        }
        if session == nil, let state = visibleState {
            Text(HerdrClient.NativeThread.statusLabel(state)).font(.caption).foregroundStyle(.secondary)
        }
        if let parent {
            if session == nil, store.openHerdrHelper?.native.map({
                $0.server == server && $0.core == core && $0.owner == owner && $0.thread.provider == runtime && $0.thread.id == thread
            }) != true {
                Button("Open session") {
                    store.open(parent.bot, helper: parent.selection)
                    openedParent()
                }.controlSize(.small).accessibilityIdentifier(runtime.rawValue + "Child.openSession")
            }
        }
        if server == SampleWorkspace.server, let parent, parent.child.isWorking {
            Button("Stop helper") { store.stopSampleTests(of: parent.bot) }
        } else if runtime == .claude, let turn = interruptibleTurn {
            let pending = sendingClaudeRequest || activity?.stopRequested == true
            Button(pending ? "Stop requested" : "Ask Claude to stop") {
                sendingClaudeRequest = true
                actionError = nil
                Task {
                    defer { sendingClaudeRequest = false }
                    do {
                        let client = try connectedClient()
                        try await client.requestClaudeStop(turn, owner: owner, core: core, thread: thread)
                        activity = try await client.threadActivity(runtime, owner: owner, core: core, thread: thread)
                    } catch { actionError = error.localizedDescription }
                }
            }.disabled(pending || readError != nil)
                .help("Ask the parent Claude session to stop this helper run. Its status updates when Claude confirms.")
                .accessibilityIdentifier("claudeChild.stop")
        } else if let turn = interruptibleTurn, runtime != .claude {
            Button(requestedTurn == turn ? "Stopping…" : "Stop helper") {
                requestedTurn = turn
                actionError = nil
                Task {
                    do {
                        try await connectedClient().interruptChildTurn(turn, runtime: runtime, owner: owner, core: core, thread: thread)
                    } catch {
                        requestedTurn = nil
                        actionError = error.localizedDescription
                    }
                }
            }.disabled(requestedTurn == turn || readError != nil)
                .accessibilityIdentifier(runtime.rawValue + "Child.stop")
        }
        if let parent {
            let title = parent.selection.archive == nil ? "Steer via " + parent.bot.name : "Open chat with " + parent.bot.name
            Button {
                if store.beginHelperSteering(parent.selection, of: parent.bot) { openedParent() }
                else { actionError = "The session that started this helper is no longer available." }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .buttonStyle(.appleProminent)
            .accessibilityLabel(title)
            .accessibilityIdentifier(runtime.rawValue + "Child.openParent")
            if session != nil, server != SampleWorkspace.server {
                let existing = store.promotedBot(for: owner, core: core, parent: parent.bot, runtime: runtime, thread: thread)
                Button(existing.map { "Open " + $0.name + " chat" } ?? "Promote to bot") {
                    var selected = parent.selection
                    selected.native = .init(thread: parent.child, core: core, owner: owner, server: server)
                    actionError = nil
                    promotion = Task {
                        defer { promotion = nil }
                        do {
                            let bot = try await store.promoteNativeHelper(selected, of: parent.bot)
                            try Task.checkCancellation()
                            store.open(bot)
                        } catch is CancellationError {
                        } catch { actionError = error.localizedDescription }
                    }
                }
                .disabled(promotion != nil || (readError != nil && existing == nil))
                .help("Open a permanent chat with this helper’s model and session history.")
                .accessibilityIdentifier(runtime.rawValue + "Child.promote")
            }
        }
    }

    private func connectedClient() throws -> HerdrClient {
        guard store.herdrServer(id: server.id) == server else {
            throw BackendError.unavailable("The workspace connection changed.")
        }
        return try store.herdrClient(for: server)
    }
}

struct NativeSessionReply: View {
    let text: String
    var media: HelperReplyMedia?
    @StateObject private var message = ChatMessage(role: .assistant, content: "")

    var body: some View {
        MarkdownContent(message: message, helperMedia: media).textSelection(.enabled)
            .onChange(of: text, initial: true) { _, value in message.content = value }
    }
}

/// The center pane shows the selected child's work. The same session can independently
/// open in the terminal inspector, including after its parent process has ended.
struct NativeSessionView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let selection: HerdrHelperSelection
    let native: HerdrHelperSelection.Native

    var body: some View {
        let listing = store.herdrHelpers[selection.parent]
        let siblings = store.herdrServer(for: bot) == native.server && listing?.core == native.core && listing?.parent == native.owner ? listing?.nativeThreads ?? [] : []
        let thread = siblings.first { $0.id == native.thread.id && $0.provider == native.thread.provider } ?? native.thread
        let back = store.backDestination(for: selection, of: bot)
        let backTitle = "Back to " + back.name
        let target = LiveTerminal(thread: thread, owner: native.owner, core: native.core)
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                Button {
                    store.open(back, of: bot)
                } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).help(backTitle).accessibilityLabel(backTitle)
                BotAvatar(bot: bot, size: 26)
                let title = thread.name + " · Helper of " + back.delegatorName(for: bot)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: title).font(.system(size: 14, weight: .semibold))
                            status(of: thread)
                        }.fixedSize()
                        Spacer(minLength: 0)
                        modelBadge(for: thread).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 5) {
                            status(of: thread).fixedSize()
                            modelBadge(for: thread)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.help(title)
                ChatTerminalPreviewButton(server: native.server, target: target)
                ShowDetailsItem()
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "helper_header")
            Divider()
            NativeThreadOutput(server: native.server, runtime: native.thread.provider, core: native.core, owner: native.owner,
                               thread: native.thread.id, detail: target.detail, session: native.thread, openedParent: {})
        }.background(AppColor.chat).accessibilityElement(children: .contain).accessibilityIdentifier("nativeSession.details")
    }
    private func status(of thread: HerdrClient.NativeThread) -> some View {
        NativeThreadDuration(thread: thread, showsStatus: true).font(.caption).foregroundStyle(.secondary)
    }

    private func modelBadge(for thread: HerdrClient.NativeThread) -> some View {
        Text(verbatim: thread.modelLine)
            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 5))
            .help(thread.modelLine)
    }

}
