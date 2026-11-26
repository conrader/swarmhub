import SwiftUI

/// Activity reported by the CLI for a child without a separate terminal.
struct NativeThreadOutput: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let runtime: HerdrClient.ChildRuntime
    let core: String
    let owner: HerdrClient.AgentRef
    let thread: String
    let detail: String
    var session: HerdrClient.NativeThread? = nil
    let openedParent: () -> Void
    @State private var activity: HerdrClient.ThreadActivity?
    @State private var requestedTurn: String?
    @State private var readError: String?
    @State private var actionError: String?

    private var parent: (selection: HerdrHelperSelection, bot: Bot, child: HerdrClient.NativeThread)? {
        for (key, list) in store.herdrHelpers where list.core == core && list.parent == owner {
            if let child = list.nativeThreads.first(where: { $0.provider == runtime && $0.id == thread }),
               let bot = store.bots.first(where: { $0.id == key.botID }), store.herdrServer(for: bot) == server {
                let selection = HerdrHelperSelection(botID: key.botID, helperID: thread, groupRuntime: key.groupRuntime,
                                                     source: key.source, archive: key.archive)
                if key.groupRuntime == nil || store.groupOwningHelper(selection, of: bot) != nil { return (selection, bot, child) }
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        cards(for: parent?.child ?? session)
                        controls
                        errors
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(parent?.child.sessionDetail ?? detail).font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { controls }
                        VStack(alignment: .leading) { controls }
                    }
                    errors
                    if let activity {
                        TerminalTextGrid(output: activity.transcript, scrollback: true)
                    } else if readError == nil { ProgressView("Connecting…") }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                do {
                    let client = try connectedClient()
                    let snapshot = try await client.threadActivity(runtime, owner: owner, core: core, thread: thread)
                    try Task.checkCancellation()
                    activity = snapshot
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

    @ViewBuilder private var errors: some View {
        if let error = actionError ?? readError { Text(error).font(.callout).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func cards(for child: HerdrClient.NativeThread) -> some View {
        let details = activity?.details
        let task = details?.task ?? child.task
        let reply = details?.reply ?? child.reply
        helperPart("Task", detail: HerdrClient.NativeThread.statusLabel(activity?.state ?? child.state)) {
            Text(verbatim: task.isEmpty ? "No task recorded." : task).textSelection(.enabled)
        }
        helperPart(details.map { $0.steps.count == 64 ? "Steps (latest 64)" : "Steps (\($0.steps.count))" } ?? "Steps", detail: child.model) {
            if let steps = details?.steps {
                if steps.isEmpty { Text("No steps recorded.").foregroundStyle(.secondary) }
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: step.text).textSelection(.enabled)
                        Spacer()
                        if let state = step.state { Text(verbatim: state).font(.caption).foregroundStyle(.secondary) }
                    }
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
                Text("No reply yet.").foregroundStyle(.secondary)
            } else {
                NativeSessionReply(text: reply)
            }
            if let terminal = details?.terminal {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "$ " + terminal.command)
                        .foregroundStyle(.secondary).lineLimit(2).help(terminal.command)
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: terminal.output).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 126).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.sidebar, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityElement(children: .contain).accessibilityIdentifier("nativeSession.commandOutput")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if session == nil, let state = activity?.state {
            Text(HerdrClient.NativeThread.statusLabel(state)).font(.caption).foregroundStyle(.secondary)
        }
        if let parent {
            if session == nil, store.openHerdrHelper?.native.map({
                $0.server == server && $0.core == core && $0.owner == owner && $0.thread.provider == runtime && $0.thread.id == thread
            }) != true {
                Button("Open session") {
                    var selection = parent.selection
                    selection.native = .init(thread: parent.child, core: core, owner: owner, server: server)
                    store.open(parent.bot, helper: selection)
                    openedParent()
                }.controlSize(.small).accessibilityIdentifier(runtime.rawValue + "Child.openSession")
            }
            let title = parent.selection.archive == nil ? "Steer via " + parent.bot.name : "Open chat with " + parent.bot.name
            Button(title) {
                if store.openHelperParent(parent.selection, of: parent.bot) { openedParent() }
            }.controlSize(.small).accessibilityIdentifier(runtime.rawValue + "Child.openParent")
        }
        if runtime != .claude, activity?.state == "working", let turn = activity?.activeTurn {
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
            }.controlSize(.small).disabled(requestedTurn == turn || readError != nil)
                .accessibilityIdentifier(runtime.rawValue + "Child.stop")
        }
    }

    private func connectedClient() throws -> HerdrClient {
        guard store.herdrServer(id: server.id) == server else {
            throw BackendError.unavailable("The workspace connection changed.")
        }
        return try store.herdrClient(for: server)
    }
}

private struct NativeSessionReply: View {
    let text: String
    @StateObject private var message = ChatMessage(role: .assistant, content: "")

    var body: some View {
        MarkdownContent(message: message).textSelection(.enabled)
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
        let siblings = listing?.core == native.core && listing?.parent == native.owner ? listing?.nativeThreads ?? [] : []
        let thread = siblings.first { $0.id == native.thread.id && $0.provider == native.thread.provider } ?? native.thread
        let ownerName = siblings.first { $0.id == thread.parent && $0.provider == thread.provider }?.name
            ?? store.delegatingSession(for: selection)?.helper.name ?? bot.name
        let target = LiveTerminal(thread: thread, owner: native.owner, core: native.core)
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ShowSidebarItem()
                Button {
                    if !store.openHelperParent(selection, of: bot) { store.open(bot) }
                } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).accessibilityLabel("Back to " + (store.groupOwningHelper(selection, of: bot)?.name ?? bot.name))
                BotAvatar(bot: bot, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: thread.name + " · Helper of " + ownerName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(thread.statusLine)
                        NativeThreadDuration(thread: thread)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let model = thread.model, !model.isEmpty {
                    Text(verbatim: thread.provider.label + " · " + model)
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 5))
                        .layoutPriority(1).help(model)
                }
                ChatTerminalPreviewButton(server: native.server, target: target)
                ShowDetailsItem()
            }.padding(.horizontal, ChromeMetrics.headerPadding).frame(height: 54).windowDragStrip(probe: "helper_header")
            Divider()
            NativeThreadOutput(server: native.server, runtime: native.thread.provider, core: native.core, owner: native.owner,
                               thread: native.thread.id, detail: target.detail, session: native.thread, openedParent: {})
        }.background(AppColor.chat).accessibilityElement(children: .contain).accessibilityIdentifier("nativeSession.details")
    }
}
