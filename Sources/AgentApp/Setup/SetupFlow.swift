import Foundation

/// What opens the setup window with something already filled in (D7 and `HistoryOnlyBanner`).
struct SetupPrefill: Equatable, Sendable {
    /// The address saved today; non-nil means "Change connection" on a configured app.
    var address: String?
    /// A `name=` line pre-seeded in the "more than one agent" fold, for a history-only agent.
    var agentName: String?
    /// Start on the address step instead of Welcome.
    var startAtAddress = false
}

/// The setup window's steps as a pure state machine (P21 item 11). No step writes anything; only the store's
/// `commitSetup` does, on S4's Add. While `OpenClawBackend.isImplemented` is false there is no "which software" step.
struct SetupFlow: Equatable {
    enum Step: String, CaseIterable, Equatable { case welcome, hosting, address, choose, done }
    enum Action: Equatable { case connectExisting, newHosted, test(SetupCheckResult), add(count: Int, first: String?), back }

    private(set) var step: Step = .welcome
    private(set) var history: [Step] = []
    var input = SetupInput()
    var result: SetupCheckResult?
    /// Names (probe ids) ticked on S4; all found agents start ticked except those already added.
    var chosen: Set<String> = []
    var confirmMove = false
    private(set) var addedCount = 0; private(set) var firstAdded: String?
    let prefill: SetupPrefill

    init(prefill: SetupPrefill = .init()) {
        self.prefill = prefill
        input.address = prefill.address ?? ""
        if let name = prefill.agentName { input.extra = "\(name)=" }
        if prefill.startAtAddress { step = .address }
    }

    /// Back and Cancel exist on every step; "Skip for now" only on the first.
    var canGoBack: Bool { !history.isEmpty && step != .done }
    var canSkip: Bool { step == .welcome }
    /// The software choice step appears only once OpenClaw works (P12).
    static var offersSoftwareChoice: Bool { OpenClawBackend.isImplemented }

    /// True when the typed address differs from the saved one, so Add needs the move confirmation (D7).
    var movesAddress: Bool {
        guard let saved = prefill.address, !saved.isEmpty, let result, let url = result.baseURL else { return false }
        return BoxAddress.normalize(saved) != url.absoluteString
    }
    var canAdd: Bool { !chosen.isEmpty && (!movesAddress || confirmMove) }

    mutating func apply(_ action: Action) {
        switch action {
        case .connectExisting: go(.address)
        case .newHosted: go(.hosting)
        case .test(let checked):
            result = checked
            guard checked.succeeded else { return }
            go(.choose)
        case .add(let count, let first): addedCount = count; firstAdded = first; history = []; step = .done
        case .back:
            guard canGoBack, let previous = history.popLast() else { return }
            step = previous
        }
    }

    /// Ticks every found agent that is not already added; called when S4 opens.
    mutating func preselect(alreadyAdded: Set<String>) {
        chosen = Set((result?.available ?? []).map(\.id)).subtracting(alreadyAdded)
    }

    private mutating func go(_ next: Step) { history.append(step); step = next }
}
