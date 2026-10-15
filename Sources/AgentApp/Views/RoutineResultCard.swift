import SwiftUI

/// "Routine finished · ok" card posted into the bot's chat by the routine inbox: the routine, when it ran, the summary,
/// and (P43) Open result with the run's whole output.
struct RoutineResultCard: View {
    let message: ChatMessage
    @State private var showingResult = false
    var body: some View {
        let failed = RoutineResultCopy.failed(message)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "clock.badge.checkmark").foregroundStyle(failed ? Color.red : Color.accentColor)
                Text(RoutineResultCopy.title(message)).font(.caption.weight(.semibold)).foregroundStyle(failed ? Color.red : Color.secondary)
                Spacer()
            }
            Text(message.metadata["routine"] ?? "Routine").font(.callout.weight(.semibold))
            Text(RoutineResultCopy.ranAt(message)).font(.caption2).foregroundStyle(.tertiary)
            if !message.content.isEmpty { Text(message.content).font(.callout).textSelection(.enabled).lineSpacing(2) }
            if let error = message.metadata["error"] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let note = message.metadata["note"] { Text(note).font(.caption).foregroundStyle(.secondary) }
            if message.metadata["sessionID"] != nil {
                Button("Open result") { showingResult = true }.controlSize(.small).help("Shows the whole output of this run")
            }
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
            .sheet(isPresented: $showingResult) { RoutineResultSheet(message: message) }
    }
}

enum RoutineResultCopy {
    static func failed(_ message: ChatMessage) -> Bool { (message.metadata["status"] ?? "ok") != "ok" || message.metadata["error"] != nil }
    /// "Routine finished · ok", "Routine failed · error".
    static func title(_ message: ChatMessage) -> String {
        (failed(message) ? "Routine failed" : "Routine finished") + " · " + (message.metadata["status"] ?? "ok")
    }
    static func ranAt(_ message: ChatMessage) -> String { "Ran " + message.createdAt.formatted(date: .abbreviated, time: .shortened) }
}

/// The run's whole output, read from its cron session (`api/sessions/{id}/messages`) when the sheet opens.
struct RoutineResultSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    /// Renders pass the text; the app reads it.
    @State var output: Loadable<String> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.metadata["routine"] ?? "Routine").font(.headline)
                    Text(RoutineResultCopy.title(message) + " · " + RoutineResultCopy.ranAt(message)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Divider()
            switch output {
            case .loading: ProgressView("Reading the run's output…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason), .unavailable(let reason): Text(reason).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .loaded(let text):
                ScrollView {
                    Text(text.isEmpty ? "This run wrote no output." : text).font(.callout).textSelection(.enabled).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(18).frame(width: 560, height: 480)
            .task { await load() }
    }

    private func load() async {
        guard case .loading = output else { return }
        guard let session = message.metadata["sessionID"], let bot = store.bots.first(where: { $0.messages.contains { $0.id == message.id } }) else {
            output = .failed("This run's output is not on the server."); return
        }
        do { output = .loaded(try await store.routineFullResult(sessionID: session, bot: bot)) }
        catch { output = .failed("The output could not be read: \(error.localizedDescription)") }
    }
}
