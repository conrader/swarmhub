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
    let openedParent: () -> Void
    @State private var activity: HerdrClient.ThreadActivity?
    @State private var requestedTurn: String?
    @State private var readError: String?
    @State private var actionError: String?

    private var parent: (selection: HerdrHelperSelection, bot: Bot)? {
        for (key, list) in store.herdrHelpers where list.core == core && list.parent == owner {
            if list.nativeThreads.contains(where: { $0.provider == runtime && $0.id == thread }),
               let bot = store.bots.first(where: { $0.id == key.botID }), store.herdrServer(for: bot) == server {
                let selection = HerdrHelperSelection(botID: key.botID, helperID: thread, groupRuntime: key.groupRuntime,
                                                     source: key.source, archive: key.archive)
                if key.groupRuntime == nil || store.groupOwningHelper(selection, of: bot) != nil { return (selection, bot) }
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if let error = actionError ?? readError { Text(error).font(.callout).foregroundStyle(.secondary) }
            if let activity {
                TerminalTextGrid(output: activity.transcript, scrollback: true)
            } else if readError == nil { ProgressView("Connecting…") }
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

    @ViewBuilder private var controls: some View {
        if let state = activity?.state {
            Text(HerdrClient.NativeThread.statusLabel(state)).font(.caption).foregroundStyle(.secondary)
        }
        if let parent {
            let title = parent.selection.archive == nil ? "Steer via " + parent.bot.name : "Open chat with " + parent.bot.name
            Button(title) {
                if store.openHelperParent(parent.selection, of: parent.bot) { openedParent() }
            }.controlSize(.small).accessibilityIdentifier(runtime.rawValue + "Child.openParent")
        }
        if runtime == .codex, activity?.state == "working", let turn = activity?.activeTurn {
            Button(requestedTurn == turn ? "Stopping…" : "Stop helper") {
                requestedTurn = turn
                actionError = nil
                Task {
                    do {
                        try await connectedClient().interruptCodexTurn(turn, owner: owner, core: core, thread: thread)
                    } catch {
                        requestedTurn = nil
                        actionError = error.localizedDescription
                    }
                }
            }.controlSize(.small).disabled(requestedTurn == turn || readError != nil)
                .accessibilityIdentifier("codexChild.stop")
        }
    }

    private func connectedClient() throws -> HerdrClient {
        guard store.herdrServer(id: server.id) == server else {
            throw BackendError.unavailable("The workspace connection changed.")
        }
        return try store.herdrClient(for: server)
    }
}
