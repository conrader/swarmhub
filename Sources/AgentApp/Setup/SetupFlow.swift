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

/// What S3-OC's Test found (P25 D4): the agents, a pairing request to approve, or one redacted line.
enum OpenClawSetupOutcome: Equatable, Sendable {
    case connected([OpenClawAgent])
    case pairingRequired(requestId: String?)
    case failed(String)
}

/// One row on S4: a Hermes probe id or an OpenClaw agent id, and its name.
struct SetupChoice: Equatable, Identifiable { let id: String; let name: String }

/// The setup window's steps as a pure state machine (P21 item 11, P25). No step writes anything except two: S4's Add
/// (`commitSetup` / `commitSetupOpenClaw`), and S3-OC's Test, which saves the Gateway it connects through and is
/// undone on Cancel, Back to `software` or closing the window (`abandonSetupGateway`).
struct SetupFlow: Equatable {
    enum Step: String, CaseIterable, Equatable { case welcome, hosting, software, address, openClaw, choose, done }
    enum Software: String, Equatable { case hermes, openClaw }
    enum Action: Equatable {
        case connectExisting, newHosted, pick(Software), test(SetupCheckResult), openClawTest(OpenClawSetupOutcome, gatewayID: String?)
        case add(count: Int, first: String?), back
    }

    private(set) var step: Step = .welcome
    private(set) var history: [Step] = []
    private(set) var software: Software?
    var input = SetupInput()
    var result: SetupCheckResult?
    /// S3-OC's fields, and its last Test (with the Gateway it used).
    var openClaw = OpenClawDraft()
    private(set) var openClawOutcome: OpenClawSetupOutcome?
    private(set) var openClawGatewayID: String?
    /// Ids ticked on S4; all found agents start ticked except those already added.
    var chosen: Set<String> = []
    var confirmMove = false
    private(set) var addedCount = 0; private(set) var firstAdded: String?
    let prefill: SetupPrefill

    init(prefill: SetupPrefill = .init()) {
        self.prefill = prefill
        input.address = prefill.address ?? ""
        if let name = prefill.agentName { input.extra = "\(name)=" }
        if prefill.startAtAddress {
            // Change connection and the history-only banner are Hermes; Back still reaches the software choice.
            step = .address; software = .hermes
            history = Self.offersSoftwareChoice ? [.welcome, .software] : []
        }
    }

    /// Back and Cancel exist on every step; "Skip for now" only on the first.
    var canGoBack: Bool { !history.isEmpty && step != .done }
    var canSkip: Bool { step == .welcome }
    /// The software choice step appears only while OpenClaw works (P12, P25 D1).
    static var offersSoftwareChoice: Bool { OpenClawBackend.isImplemented }

    /// True when the typed address differs from the saved one, so Add needs the move confirmation (D7). Hermes only.
    var movesAddress: Bool {
        guard software != .openClaw, let saved = prefill.address, !saved.isEmpty, let result, let url = result.baseURL else { return false }
        return BoxAddress.normalize(saved) != url.absoluteString
    }
    var canAdd: Bool { !chosen.isEmpty && (!movesAddress || confirmMove) }

    /// S3-OC's Test reads "Test again" after the Gateway asked for approval.
    var awaitsPairing: Bool { if case .pairingRequired = openClawOutcome { true } else { false } }
    /// The request id for the approve command, when the Gateway sent one.
    var pairingRequestId: String? { if case .pairingRequired(let id) = openClawOutcome { id } else { nil } }
    var openClawFailure: String? { if case .failed(let line) = openClawOutcome { line } else { nil } }
    var openClawAgents: [OpenClawAgent] { if case .connected(let agents) = openClawOutcome { agents } else { [] } }

    /// S4's rows for the software chosen.
    var choices: [SetupChoice] {
        software == .openClaw ? openClawAgents.map { SetupChoice(id: $0.id, name: $0.displayName) }
                              : (result?.available ?? []).map { SetupChoice(id: $0.id, name: $0.name) }
    }

    mutating func apply(_ action: Action) {
        switch action {
        case .connectExisting: go(Self.offersSoftwareChoice ? .software : .address); if !Self.offersSoftwareChoice { software = .hermes }
        case .newHosted: go(.hosting)
        case .pick(let picked):
            software = picked
            go(picked == .hermes ? .address : .openClaw)
        case .test(let checked):
            result = checked
            guard checked.succeeded else { return }
            go(.choose)
        case .openClawTest(let outcome, let gatewayID):
            openClawOutcome = outcome; openClawGatewayID = gatewayID
            guard case .connected = outcome else { return }
            go(.choose)
        case .add(let count, let first): addedCount = count; firstAdded = first; history = []; step = .done
        case .back:
            guard canGoBack, let previous = history.popLast() else { return }
            step = previous
            // Back to the choice undoes S3-OC's Test (its Gateway is forgotten by the window).
            if previous == .software || previous == .welcome { openClawOutcome = nil; openClawGatewayID = nil }
        }
    }

    /// Ticks every found agent that is not already added; called when S4 opens.
    mutating func preselect(alreadyAdded: Set<String>) {
        chosen = Set(choices.map(\.id)).subtracting(alreadyAdded)
    }

    private mutating func go(_ next: Step) { history.append(step); step = next }
}
