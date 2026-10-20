import Foundation

/// What a document's button or form submit can make the app do: existing local commands only (CORE-PLAN.md §5.1,
/// §5.2). Nothing here decides, approves, enrolls, reads a secret or opens an approval or secret screen; `navigate`
/// reaches only `SDUIScreen`, which has none.
public enum SDUIAppCommand: Equatable, Sendable {
    case dismiss, refresh
    case copyText(String)
    /// Only after the user confirmed, and only for a host in the compiled allowlist.
    case openURL(URL)
    case navigate(SDUIScreen)
    case routineOpen(String), routineRunNow(String), routinePause(String), routineResume(String)
    /// The existing create path (name, schedule, prompt).
    case routineCreate(SDUIRoutineDraft)
    /// The existing save path for the routine with this id.
    case routineSave(String, SDUIRoutineDraft)
}

/// The fields the existing routine create and save paths take. `prompt` nil: the document has no prompt field, so
/// the routine keeps its prompt (empty for a new one).
public struct SDUIRoutineDraft: Equatable, Sendable {
    public let name: String
    public let schedule: String
    public let prompt: String?

    public init(name: String, schedule: String, prompt: String?) {
        self.name = name; self.schedule = schedule; self.prompt = prompt
    }
}

public struct SDUIConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let button: String
    public let command: SDUIAppCommand
}

/// Turns a resolved action into one step for the renderer. Platform-neutral; the app supplies only the sink that
/// performs `SDUIAppCommand`s.
public struct SDUIActionRouter: Sendable {
    public enum Step: Equatable, Sendable {
        /// Move the enclosing flow by this many steps (renderer state only).
        case moveFlow(Int)
        case perform(SDUIAppCommand)
        /// Ask first; perform `confirmation.command` only if the user agrees.
        case confirm(SDUIConfirmation)
        /// Nothing happens; the reason is for logs and tests.
        case refused(String)
    }

    /// The app's compiled `open_url` allowlist. Checked again here although the decoder already checked it.
    public let urlHosts: Set<String>

    public init(urlHosts: Set<String>) { self.urlHosts = urlHosts }

    /// A button press. `label` is the button's text, used in a confirmation.
    public func route(_ action: SDUIResolvedAction, label: String) -> Step {
        let command: SDUIAppCommand
        switch action.command {
        case .flowNext: return .moveFlow(1)
        case .flowBack: return .moveFlow(-1)
        case .routineCreate, .routineSave: return .refused("submit_outside_form")
        case .dismiss: command = .dismiss
        case .refresh: command = .refresh
        case .copyText: command = .copyText(action.argument ?? "")
        case .openURL:
            guard let url = allowedURL(action.argument) else { return .refused("url_not_allowed") }
            return .confirm(SDUIConfirmation(title: "Open this link?", message: url.absoluteString, button: "Open",
                                             command: .openURL(url)))
        case .navigate:
            guard let screen = action.argument.flatMap(SDUIScreen.init(rawValue:)) else { return .refused("unknown_screen") }
            command = .navigate(screen)
        case .routineOpen, .routineRunNow, .routinePause, .routineResume:
            guard let id = action.argument, !id.isEmpty else { return .refused("routine_unavailable") }
            switch action.command {
            case .routineOpen: command = .routineOpen(id)
            case .routineRunNow: command = .routineRunNow(id)
            case .routinePause: command = .routinePause(id)
            default: command = .routineResume(id)
            }
        }
        return confirmed(command, action: action, label: label)
    }

    /// A form submit with the form's current values. Field rules first (required, max length), then the routine
    /// path's own limits; only `routine.create` and `routine.save` can be submitted.
    public func submit(_ form: SDUIRenderForm, values: [String: SDUIFieldValue]) -> Step {
        let values = form.initial.merging(values) { _, new in new }
        let problems = Self.fieldProblems(form, values: values)
        if let field = form.fields.first(where: { problems[$0.id] != nil }) { return .refused(problems[field.id]!) }
        guard let draft = SDUIRoutineTarget.draft(values) else { return .refused("invalid_form") }
        switch form.submit.command {
        case .routineCreate:
            return confirmed(.routineCreate(draft), action: form.submit, label: form.submitLabel)
        case .routineSave:
            guard let id = form.submit.argument, !id.isEmpty else { return .refused("routine_unavailable") }
            return confirmed(.routineSave(id, draft), action: form.submit, label: form.submitLabel)
        default:
            return .refused("not_a_submit")
        }
    }

    /// Field id → problem (`required`, `too_long`) for the visible fields.
    public static func fieldProblems(_ form: SDUIRenderForm, values: [String: SDUIFieldValue]) -> [String: String] {
        var problems: [String: String] = [:]
        for field in form.fields {
            let value = values[field.id] ?? form.initial[field.id] ?? .text("")
            guard case .text(let text) = value else { continue }
            if field.required, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems[field.id] = "required" }
            else if let limit = field.maxLength, Int64(text.count) > limit { problems[field.id] = "too_long" }
        }
        return problems
    }

    /// The URL, only when it still has the decoder's shape and its host is in the compiled allowlist.
    public func allowedURL(_ text: String?) -> URL? {
        guard let text, text.utf8.count <= SDUICatalog.maxURLBytes, matches(text, SDUICatalog.urlPattern) else { return nil }
        let host = String(text.dropFirst("https://".count).prefix { $0 != "/" && $0 != "?" })
        guard urlHosts.contains(host), let url = URL(string: text), url.scheme == "https", url.host() == host else { return nil }
        return url
    }

    private func confirmed(_ command: SDUIAppCommand, action: SDUIResolvedAction, label: String) -> Step {
        guard action.requiresConfirmation else { return .perform(command) }
        return .confirm(SDUIConfirmation(title: label + "?", message: "", button: label, command: command))
    }
}
