import AppKit
import SwiftUI
import SwarmHubCore

/// P7b first targets. Each host shows the compiled view it replaces unless the current bundle has a document for the
/// view that decodes and fits (`SDUIRoutineTarget`): no bundle, no document, a decoder fallback or a `kill.view.*`
/// flag → the compiled view, exactly as before; a `critical` document this build cannot read → "update required".
struct RoutineResultCardHost: View {
    @Environment(\.sduiViewSource) private var source
    let message: ChatMessage

    var body: some View {
        switch SDUIRoutineTarget.resultCard(source) {
        case .compiled: RoutineResultCard(message: message)
        case .updateRequired: SDUIUpdateRequiredView(inSheet: false)
        case .document(let document): RoutineResultCardDocument(message: message, document: document, policy: source.policy)
        }
    }
}

struct RoutineEditorHost: View {
    @Environment(\.sduiViewSource) private var source
    let bot: Bot
    let job: HermesJob?

    var body: some View {
        switch SDUIRoutineTarget.editor(source, routineID: job?.id, data: RoutineSDUIData.editor(bot: bot, job: job)) {
        case .compiled: RoutineEditorSheet(bot: bot, job: job)
        case .updateRequired: SDUIUpdateRequiredView(inSheet: true)
        case .document(let document): RoutineEditorDocument(bot: bot, job: job, document: document, policy: source.policy)
        }
    }
}

/// The compiled "update required" view (CORE-PLAN.md §5.4).
struct SDUIUpdateRequiredView: View {
    @Environment(\.dismiss) private var dismiss
    let inSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(verbatim: "Update required") } icon: { Image(systemName: "arrow.down.circle") }.font(.callout.weight(.semibold))
            Text(verbatim: "This view needs a newer version of \(AppConstants.name). Install the latest update to see it.")
                .font(.caption).foregroundStyle(.secondary)
            if inSheet { HStack { Spacer(); Button { dismiss() } label: { Text(verbatim: "Done") }.keyboardShortcut(.defaultAction) } }
        }.padding(inSheet ? 22 : 12).frame(maxWidth: inSheet ? 470 : 500, alignment: .leading)
            .background(inSheet ? Color.clear : AppColor.card, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct RoutineResultCardDocument: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let message: ChatMessage
    let document: SDUIDocument
    let policy: SDUIPolicy

    var body: some View {
        let bot = store.bots.first { $0.messages.contains { $0.id == message.id } }
        let job = bot.flatMap { RoutineSDUIData.job(message.metadata["jobID"], bot: $0, store: store) }
        SDUIDocumentView(document: document, data: RoutineSDUIData.card(message, bot: bot, job: job),
                         actions: RoutineSDUICommands(store: store, bot: bot, job: job, dismiss: nil,
                                                      open: { $0.perform(in: store, openSettings: openSettings, openWindow: openWindow) })
                            .actions(policy))
    }
}

private struct RoutineEditorDocument: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let bot: Bot
    let job: HermesJob?
    let document: SDUIDocument
    let policy: SDUIPolicy

    var body: some View {
        ScrollView {
            SDUIDocumentView(document: document, data: RoutineSDUIData.editor(bot: bot, job: job),
                             actions: RoutineSDUICommands(store: store, bot: bot, job: job, dismiss: { dismiss() },
                                 open: { $0.perform(in: store, openSettings: openSettings, openWindow: openWindow) }).actions(policy))
                .padding(22)
        }.frame(width: 520).frame(minHeight: 420).transaction { $0.animation = nil }
    }
}

/// Local data the routine documents may bind (SCHEMAS.md §13 roots `routine`, `result`, `profile`). Session ids,
/// keys and anything else on the binding denylist are never put here.
@MainActor enum RoutineSDUIData {
    static func job(_ id: String?, bot: Bot, store: AppStore) -> HermesJob? {
        guard let id else { return nil }
        return store.routines.state(for: bot.id).jobs.value?.first { $0.id == id }
    }

    static func routine(_ job: HermesJob) -> [String: SDUIDataValue] {
        var values: [String: SDUIDataValue] = [
            "routine.id": .string(job.id), "routine.name": .string(job.name), "routine.prompt": .string(job.prompt),
            "routine.schedule": .string(job.schedule), "routine.schedule_text": .string(RoutineScheduleDraft.describe(job.schedule)),
            "routine.enabled": .bool(!job.isPaused), "routine.state": .string(job.state)
        ]
        if let status = job.lastStatus { values["routine.last_status"] = .string(status) }
        return values
    }

    static func editor(bot: Bot, job: HermesJob?) -> SDUIData {
        var values = job.map(routine) ?? [:]
        values["profile.name"] = .string(bot.name)
        return SDUIData(values)
    }

    /// The card's own fields (as `RoutineResultCard` shows them), plus the routine when it is loaded.
    static func card(_ message: ChatMessage, bot: Bot?, job: HermesJob?) -> SDUIData {
        var values = job.map(routine) ?? [:]
        values["routine.name"] = .string(message.metadata["routine"] ?? "Routine")
        if let id = message.metadata["jobID"] { values["routine.id"] = .string(id) }
        values["result.status"] = .string(message.metadata["status"] ?? "ok")
        values["result.failed"] = .bool(RoutineResultCopy.failed(message))
        values["result.title"] = .string(RoutineResultCopy.title(message))
        values["result.ran_text"] = .string(RoutineResultCopy.ranAt(message))
        values["result.finished_at"] = .string(message.createdAt.formatted(date: .abbreviated, time: .shortened))
        values["result.has_output"] = .bool(message.metadata["sessionID"] != nil)
        if !message.content.isEmpty { values["result.summary"] = .string(message.content) }
        if let error = message.metadata["error"] { values["result.error"] = .string(error) }
        if let note = message.metadata["note"] { values["result.note"] = .string(note) }
        if let bot { values["profile.name"] = .string(bot.name) }
        return SDUIData(values)
    }
}

/// The Mac side of `SDUIAppCommand`: existing app code paths only.
@MainActor struct RoutineSDUICommands {
    let store: AppStore
    let bot: Bot?
    /// The routine the view is about (the edited one, or the card's when loaded).
    let job: HermesJob?
    /// Present in a sheet; nil in a chat card.
    let dismiss: (@MainActor () -> Void)?
    /// Runs an existing menu command (`AppCommand.perform`), which needs the window's settings and window actions.
    let open: @MainActor (AppCommand) -> Void

    func actions(_ policy: SDUIPolicy) -> SDUIMacActions {
        SDUIMacActions(router: SDUIActionRouter(urlHosts: policy.urlHosts), isAvailable: { isAvailable($0) },
                       perform: { await perform($0) })
    }

    /// Screens the Mac can open today; the others are not offered.
    static func appCommand(_ screen: SDUIScreen) -> AppCommand? {
        switch screen {
        case .routines: .routines
        case .skills: .skills
        case .settings: .settings
        case .chat, .boxes, .updates: nil
        }
    }

    func isAvailable(_ command: SDUIAppCommand) -> Bool {
        switch command {
        case .dismiss: return dismiss != nil
        case .refresh: return bot?.backend == .hermes
        case .copyText, .openURL: return true
        case .navigate(let screen): return Self.appCommand(screen) != nil
        case .routineOpen(let id): return store.selectedBot?.id == bot?.id && job?.id == id
        case .routineRunNow(let id), .routinePause(let id), .routineResume(let id): return bot != nil && job?.id == id
        case .routineCreate: return dismiss != nil && bot != nil && job == nil
        case .routineSave(let id, _): return dismiss != nil && bot != nil && job?.id == id
        }
    }

    func perform(_ command: SDUIAppCommand) async -> String? {
        guard isAvailable(command) else { return nil }
        switch command {
        case .dismiss: dismiss?()
        case .refresh: if let bot { await store.refreshRoutines(for: bot) }
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openURL(let url): ExternalLink.open(url)
        case .navigate(let screen): if let command = Self.appCommand(screen) { open(command) }
        case .routineOpen: open(.routines)
        case .routineRunNow: if let bot, let job { await store.runRoutineNow(job, for: bot) }
        case .routinePause: if let bot, let job { await store.setRoutine(job, enabled: false, for: bot) }
        case .routineResume: if let bot, let job { await store.setRoutine(job, enabled: true, for: bot) }
        case .routineCreate(let draft):
            guard let bot else { return nil }
            if let failure = await store.createRoutine(for: bot, name: draft.name, schedule: draft.schedule, prompt: draft.prompt ?? "") {
                return failure
            }
            dismiss?()
        case .routineSave(_, let draft):
            guard let bot, let job else { return nil }
            if let failure = await store.updateRoutine(job, for: bot, name: draft.name, schedule: draft.schedule,
                                                       prompt: draft.prompt ?? job.prompt) {
                return failure
            }
            dismiss?()
        }
        return nil
    }
}
