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

/// What the Herdr screen's Test found: a server that answers (with the access key Test used, when it was typed or
/// read from the server, and the starter agents it can run), nothing on this Mac's port, or one plain line.
enum HerdrSetupOutcome: Equatable, Sendable {
    case connected(server: HerdrServer, key: String?, starters: [HerdrStarter])
    case nothingHere(port: Int)
    case failed(String)
}

/// One row on S4: a Hermes probe id, an OpenClaw agent id or a Herdr starter's template, and its name.
struct SetupChoice: Equatable, Identifiable { let id: String; let name: String }

/// P35: what the scan after a Hermes Test found on the box: the bot that will set up the others (a new manager when the
/// connection has none), how many bots the box listed, those that answer with their derived key (added like the
/// others), those SwarmHub can connect, and those that need their own key.
struct SetupBoxScan: Equatable, Sendable {
    var managerName: String; var managerProfile: String; var managerIsNew: Bool
    var listed: Int; var derived: [String] = []; var adoptable: [String] = []; var needsKey: [String] = []
}

/// The setup window's steps as a pure state machine (P21 item 11, P25). No step writes anything except two: S4's Add
/// (`commitSetup` / `commitSetupOpenClaw` / `commitSetupHerdr`), and S3-OC's Test, which saves the Gateway it connects through and is
/// undone on Cancel, Back to `software` or closing the window (`abandonSetupGateway`).
struct SetupFlow: Equatable {
    enum Step: String, CaseIterable, Equatable { case welcome, hosting, software, address, openClaw, herdr, choose, done }
    enum Software: String, Equatable { case hermes, openClaw, herdr }
    enum Action: Equatable {
        case connectExisting, newHosted, pick(Software), test(SetupCheckResult), openClawTest(OpenClawSetupOutcome, gatewayID: String?)
        /// Herdr: where it runs was chosen on Welcome; its screen's Test finished.
        case pickHerdr(HerdrServer.Kind), herdrTest(HerdrSetupOutcome)
        case add(count: Int, first: String?), back
        /// P35: the box scan finished (nil: it could not list the bots).
        case boxScanned(SetupBoxScan?)
    }
    enum BoxLook: Equatable { case idle, looking, found(SetupBoxScan), failed }

    private(set) var step: Step = .welcome
    private(set) var history: [Step] = []
    private(set) var software: Software?
    var input = SetupInput()
    var result: SetupCheckResult?
    /// S3-OC's fields, and its last Test (with the Gateway it used).
    var openClaw = OpenClawDraft()
    private(set) var openClawOutcome: OpenClawSetupOutcome?
    private(set) var openClawGatewayID: String?
    /// The Herdr screen's fields and its last Test.
    var herdr = HerdrServerDraft()
    private(set) var herdrOutcome: HerdrSetupOutcome?
    /// Ids ticked on S4; all found agents start ticked except those already added.
    var chosen: Set<String> = []
    var confirmMove = false
    private(set) var addedCount = 0; private(set) var firstAdded: String?
    /// P35: the box scan, whether S4's "Connect these too" is on, and the bots being connected after Add.
    private(set) var box = BoxLook.idle
    var adoptOn = true
    var adopting: [String] = []
    var boxScan: SetupBoxScan? { if case .found(let scan) = box { scan } else { nil } }
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
    /// A Herdr server is worth saving with no starter agent ticked; the other paths add at least one agent.
    var canAdd: Bool { software == .herdr ? herdrServer != nil : !chosen.isEmpty && (!movesAddress || confirmMove) }

    /// What Herdr's Test connected to, for Add.
    var herdrServer: HerdrServer? { if case .connected(let server, _, _) = herdrOutcome { server } else { nil } }
    var herdrKey: String? { if case .connected(_, let key, _) = herdrOutcome { key } else { nil } }
    var herdrStarters: [HerdrStarter] { if case .connected(_, _, let starters) = herdrOutcome { starters } else { [] } }
    var herdrFailure: String? { if case .failed(let line) = herdrOutcome { line } else { nil } }
    /// The port nothing answered on, when this Mac has no Herdr running.
    var herdrNothingHere: Int? { if case .nothingHere(let port) = herdrOutcome { port } else { nil } }

    /// S3-OC's Test reads "Test again" after the Gateway asked for approval.
    var awaitsPairing: Bool { if case .pairingRequired = openClawOutcome { true } else { false } }
    /// The request id for the approve command, when the Gateway sent one.
    var pairingRequestId: String? { if case .pairingRequired(let id) = openClawOutcome { id } else { nil } }
    var openClawFailure: String? { if case .failed(let line) = openClawOutcome { line } else { nil } }
    var openClawAgents: [OpenClawAgent] { if case .connected(let agents) = openClawOutcome { agents } else { [] } }

    /// S4's rows for the software chosen.
    var choices: [SetupChoice] {
        guard software != .openClaw else { return openClawAgents.map { SetupChoice(id: $0.id, name: $0.displayName) } }
        guard software != .herdr else { return herdrStarters.map { SetupChoice(id: $0.id, name: $0.name) } }
        let probed = (result?.available ?? []).map { SetupChoice(id: $0.id, name: $0.name) }
        let derived = (boxScan?.derived ?? []).filter { name in !probed.contains { $0.id == name } }
        return probed + derived.map { SetupChoice(id: $0, name: HermesProfileNaming.botName(forProfile: $0)) }
    }

    mutating func apply(_ action: Action) {
        switch action {
        case .connectExisting: go(Self.offersSoftwareChoice ? .software : .address); if !Self.offersSoftwareChoice { software = .hermes }
        case .newHosted: go(.hosting)
        case .pick(let picked):
            software = picked
            switch picked { case .hermes: go(.address); case .openClaw: go(.openClaw); case .herdr: herdrOutcome = nil; go(.herdr) }
        case .test(let checked):
            result = checked; box = .idle
            guard checked.succeeded else { return }
            box = .looking
            go(.choose)
        case .boxScanned(let scan):
            guard box == .looking else { return }
            box = scan.map(BoxLook.found) ?? .failed
            chosen.formUnion(scan?.derived ?? [])
        case .openClawTest(let outcome, let gatewayID):
            openClawOutcome = outcome; openClawGatewayID = gatewayID
            guard case .connected = outcome else { return }
            go(.choose)
        case .pickHerdr(let kind):
            software = .herdr; herdr = HerdrServerDraft(kind: kind); herdrOutcome = nil
            go(.herdr)
        case .herdrTest(let outcome):
            herdrOutcome = outcome
            guard case .connected = outcome else { return }
            go(.choose)
        case .add(let count, let first): addedCount = count; firstAdded = first; history = []; step = .done
        case .back:
            guard canGoBack, let previous = history.popLast() else { return }
            step = previous
            // Back to the choice undoes S3-OC's Test (its Gateway is forgotten by the window).
            if previous == .software || previous == .welcome { openClawOutcome = nil; openClawGatewayID = nil; herdrOutcome = nil }
        }
    }

    /// Ticks every found agent that is not already added; called when S4 opens.
    mutating func preselect(alreadyAdded: Set<String>) {
        chosen = Set(choices.map(\.id)).subtracting(alreadyAdded)
    }

    private mutating func go(_ next: Step) { history.append(step); step = next }
}
