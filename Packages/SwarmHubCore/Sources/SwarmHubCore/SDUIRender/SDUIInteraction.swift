import Foundation

/// The flow a button sits in: the flow node's render key and its step count. nil outside a flow.
public struct SDUIFlowPosition: Equatable, Sendable {
    public let key: String
    public let count: Int

    public init(key: String, count: Int) { self.key = key; self.count = count }
}

/// What a rendered document may ask the app for. The router decides (flow moves, confirmations, refusals); the
/// platform supplies only the sink: `isAvailable` says whether a command can run in this view and `perform` runs it
/// (nil = done, else the failure to show).
public struct SDUIActions {
    public let router: SDUIActionRouter
    public let isAvailable: @MainActor (SDUIAppCommand) -> Bool
    public let perform: @MainActor (SDUIAppCommand) async -> String?

    public init(router: SDUIActionRouter, isAvailable: @escaping @MainActor (SDUIAppCommand) -> Bool,
                perform: @escaping @MainActor (SDUIAppCommand) async -> String?) {
        self.router = router; self.isAvailable = isAvailable; self.perform = perform
    }
}

/// The state of one document on screen, shared by the Mac (P7b) and iOS (P7c) renderers so both behave the same:
/// form values, flow steps, the pending confirmation, whether a command is running and its failure. A view keeps one
/// of these in `@State`, draws `tree`, and runs the command a press, submit or confirmation hands back through
/// `start` / `finish`. Nothing here is platform code.
public struct SDUIInteraction: Equatable, Sendable {
    /// A confirmation waiting for the user, with the flow the button belonged to.
    public struct Pending: Equatable, Sendable {
        public let request: SDUIConfirmation
        public let flow: SDUIFlowPosition?
    }

    /// Form id → field id → value the user entered (fields not touched keep their initial value).
    public private(set) var forms: [String: [String: SDUIFieldValue]] = [:]
    /// Flow render key → current step index.
    public private(set) var steps: [String: Int] = [:]
    public private(set) var confirmation: Pending?
    public private(set) var failure: String?
    public private(set) var busy = false

    public init() {}

    public func tree(_ document: SDUIDocument, data: SDUIData) -> SDUIRenderNode? {
        SDUIRenderer.tree(document, data: data, forms: forms)
    }

    public func value(_ form: SDUIRenderForm, _ field: String) -> SDUIFieldValue {
        forms[form.id]?[field] ?? form.initial[field] ?? .text("")
    }

    public mutating func setValue(_ value: SDUIFieldValue, form: SDUIRenderForm, field: String) {
        forms[form.id, default: [:]][field] = value
    }

    public func problems(_ form: SDUIRenderForm) -> [String: String] {
        SDUIActionRouter.fieldProblems(form, values: forms[form.id] ?? [:])
    }

    /// The step a flow shows: the stored one, kept within its steps.
    public func step(_ flow: SDUIFlowPosition) -> Int { min(steps[flow.key] ?? 0, max(flow.count - 1, 0)) }

    /// Stands in for the form's values when asking whether a submit can run here; the router checks the real ones.
    static let probe = SDUIRoutineDraft(name: "", schedule: "", prompt: nil)

    /// Whether a button or form submit is enabled: refused actions and flow moves outside a flow never are; anything
    /// else asks the sink about the command it would run.
    @MainActor public static func isAvailable(_ action: SDUIResolvedAction, flow: SDUIFlowPosition?, actions: SDUIActions) -> Bool {
        // A form submit is not a button action (`route` refuses it); ask the sink about the routine path itself.
        switch action.command {
        case .routineCreate: return actions.isAvailable(.routineCreate(probe))
        case .routineSave: return actions.isAvailable(.routineSave(action.argument ?? "", probe))
        default: break
        }
        switch actions.router.route(action, label: "") {
        case .moveFlow: return flow != nil
        case .perform(let command): return actions.isAvailable(command)
        case .confirm(let pending):
            switch pending.action {
            case .moveFlow: return flow != nil
            case .perform(let command): return actions.isAvailable(command)
            }
        case .refused: return false
        }
    }

    /// A button press. Returns the command to run now, if any (`start` decides whether it may).
    public mutating func press(_ action: SDUIResolvedAction, label: String, flow: SDUIFlowPosition?,
                               router: SDUIActionRouter) -> SDUIAppCommand? {
        handle(router.route(action, label: label), flow: flow)
    }

    /// A form submit with the values entered so far.
    public mutating func submit(_ form: SDUIRenderForm, router: SDUIActionRouter) -> SDUIAppCommand? {
        handle(router.submit(form, values: forms[form.id] ?? [:]), flow: nil)
    }

    /// The user's answer to `pending` (the one the dialog presented): accept runs or moves, decline does nothing.
    public mutating func resolve(_ pending: Pending, accepted: Bool) -> SDUIAppCommand? {
        confirmation = nil
        return handle(pending.request.resolve(accepted: accepted), flow: pending.flow)
    }

    /// The dialog closed without an answer.
    public mutating func dismissConfirmation() { confirmation = nil }

    mutating func handle(_ step: SDUIActionRouter.Step, flow: SDUIFlowPosition?) -> SDUIAppCommand? {
        failure = nil
        switch step {
        case .moveFlow(let delta):
            guard let flow else { return nil }
            steps[flow.key] = min(max((steps[flow.key] ?? 0) + delta, 0), max(flow.count - 1, 0))
            return nil
        case .perform(let command): return command
        case .confirm(let pending):
            confirmation = Pending(request: pending, flow: flow)
            return nil
        case .refused: return nil
        }
    }

    /// True (and busy) when `command` may run now: the sink still offers it and no other command is running.
    @MainActor public mutating func start(_ command: SDUIAppCommand, actions: SDUIActions) -> Bool {
        confirmation = nil
        guard actions.isAvailable(command), !busy else { return false }
        busy = true
        return true
    }

    public mutating func finish(failure: String?) {
        self.failure = failure
        busy = false
    }
}
