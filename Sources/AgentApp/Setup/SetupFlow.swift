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
/// read from the server, and what it can run), nothing on this Mac's port, or one plain line.
enum HerdrSetupOutcome: Equatable, Sendable {
    case connected(server: HerdrServer, key: String?, offer: HerdrOffer)
    case nothingHere(port: Int)
    case failed(String)
}

/// A bot that is already on the server the wizard is setting up: it can stay or become the main bot, its name is
/// taken, and its agent program needs no second bot. `template` nil: it starts from the server's first.
struct HerdrSetupBot: Equatable, Identifiable, Sendable { let id: UUID; let name: String; let isMain: Bool; var template: String? = nil }

/// The wizard's main bot until its last button: an existing bot that stays or becomes the main bot (`keep`), or a new
/// one with a name, an avatar, optional instructions, and the agent program and model it starts on. `model` empty is
/// the program's default, the first model the server offers for it.
struct HerdrMainBotDraft: Equatable {
    /// The look every new main bot starts with is derived from this, so the avatar shown is the avatar created.
    static let avatarSeed = "main-bot"
    var keep: UUID?
    var name = WizardCopy.suggestedName
    var instructions = ""
    var avatar = AvatarChoice.unpicked
    var template = "", model = ""

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Called when a server was read: its main bot is offered to stay, and the program and model fall back to the
    /// server's first when the ones chosen before are not offered there.
    mutating func begin(offer: HerdrOffer, bots: [HerdrSetupBot]) {
        keep = bots.first(where: \.isMain)?.id
        if case .unpicked = avatar { let mark = GrokDefaultLook.mark(for: Self.avatarSeed); avatar = .mark(shape: mark.shape, colour: mark.colour) }
        if offer.program(template) == nil { template = offer.programs.first?.template ?? ""; model = "" }
        if !model.isEmpty, offer.program(template)?.models.contains(where: { $0.id == model }) != true { model = "" }
    }
}

/// One row on S4: a Hermes probe id or an OpenClaw agent id, and its name.
struct SetupChoice: Equatable, Identifiable { let id: String; let name: String }

/// P35: what the scan after a Hermes Test found on the box: the bot that will set up the others (a new manager when the
/// connection has none), how many bots the box listed, those that answer with their derived key (added like the
/// others), those SwarmHub can connect, and those that need their own key.
struct SetupBoxScan: Equatable, Sendable {
    var managerName: String; var managerProfile: String; var managerIsNew: Bool
    var listed: Int; var derived: [String] = []; var adoptable: [String] = []; var needsKey: [String] = []
}

/// The setup window's steps as a pure state machine (P21 item 11, P25). No step writes anything except two: the last
/// button (`commitSetup` / `commitSetupOpenClaw` on S4, `commitSetupWizard` for Herdr), and S3-OC's Test, which saves
/// the Gateway it connects through and is undone on Cancel, Back to `software` or closing the window (`abandonSetupGateway`).
///
/// Herdr is a wizard of four steps: where bots run (`welcome`), Connect (`herdr`), the main bot (`mainBot`) and the
/// optional bots (`moreBots`). Its last button creates everything at once and the window closes on the main bot's
/// chat, so closing it earlier leaves nothing behind. A server that was set up before starts at the main bot.
struct SetupFlow: Equatable {
    enum Step: String, CaseIterable, Equatable { case welcome, hosting, software, address, openClaw, herdr, mainBot, moreBots, choose, done }
    enum Software: String, Equatable { case hermes, openClaw, herdr }
    enum Action: Equatable {
        case connectExisting, newHosted, pick(Software), test(SetupCheckResult), openClawTest(OpenClawSetupOutcome, gatewayID: String?)
        /// Herdr: where it runs was chosen on Welcome; its screen's Test finished (`bots`: the bots already on that
        /// server); Continue was pressed on Connect or on the main bot.
        case pickHerdr(HerdrServer.Kind), herdrTest(HerdrSetupOutcome, bots: [HerdrSetupBot] = []), advance
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
    /// Where bots run, as selected on Welcome (This Mac unless the person picks another).
    var place = HerdrServer.Kind.local
    /// The Herdr screen's fields, its last Test and the fields that Test ran with: a result counts while they are unchanged.
    var herdr = HerdrServerDraft()
    private(set) var herdrOutcome: HerdrSetupOutcome?
    private(set) var herdrTested: HerdrServerDraft?
    /// The bots already on the tested server.
    private(set) var herdrBots: [HerdrSetupBot] = []
    var mainBot = HerdrMainBotDraft()
    /// Templates ticked on "More bots"; none to begin with, so nothing is added unasked.
    var moreBots: Set<String> = []
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

    /// A Herdr server that is already set up: Connect is skipped and the window opens on the main bot, which waits for
    /// what the server offers (`herdrTest`). Back leads to where bots run.
    init(saved server: HerdrServer) {
        prefill = .init()
        software = .herdr; herdr = HerdrServerDraft(server: server); place = server.kind
        step = .mainBot; history = [.welcome]
    }

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
    /// S4's Add needs an agent ticked (Herdr has no S4: its wizard ends on the main bot or the optional bots).
    var canAdd: Bool { !chosen.isEmpty && (!movesAddress || confirmMove) }

    /// What Herdr's Test connected to, and what that server offers.
    var herdrServer: HerdrServer? { if case .connected(let server, _, _) = herdrOutcome { server } else { nil } }
    var herdrKey: String? { if case .connected(_, let key, _) = herdrOutcome { key } else { nil } }
    var herdrOffer: HerdrOffer? { if case .connected(_, _, let offer) = herdrOutcome { offer } else { nil } }
    var herdrFailure: String? { if case .failed(let line) = herdrOutcome { line } else { nil } }
    /// The port nothing answered on, when this Mac has no Herdr running.
    var herdrNothingHere: Int? { if case .nothingHere(let port) = herdrOutcome { port } else { nil } }
    /// Test passed for the fields as they are now and the server has an agent program: Connect can be left.
    var herdrReady: Bool { herdrServer != nil && herdrTested == herdr && herdrOffer?.programs.isEmpty == false }
    /// Test reached Herdr Core, but it has no agent program to start: a bot there could not answer.
    var herdrNoPrograms: Bool { herdrServer != nil && herdrOffer?.programs.isEmpty == true }
    /// The wizard is still waiting for what a saved server offers.
    var readsSavedServer: Bool { step == .mainBot && herdrOutcome == nil }

    /// The bot that stays or becomes the main bot, when the person chose one of the server's.
    var keptMainBot: HerdrSetupBot? { mainBot.keep.flatMap { id in herdrBots.first { $0.id == id } } }
    var mainBotName: String { keptMainBot?.name ?? mainBot.trimmedName }
    /// One plain line for what the main bot still needs; nil when the step can be left.
    var mainBotProblem: String? {
        guard keptMainBot == nil else { return nil }
        let name = mainBot.trimmedName
        if name.isEmpty { return WizardCopy.nameMissing }
        if herdrBots.contains(where: { $0.name.lowercased() == name.lowercased() }) { return WizardCopy.nameTaken(name) }
        return herdrOffer?.program(mainBot.template) == nil ? WizardCopy.programMissing : nil
    }
    var mainBotReady: Bool { herdrOffer != nil && mainBotProblem == nil }

    /// "More bots": one per agent program of the server that has no bot yet and is not the main bot's own.
    var moreChoices: [HerdrProgram] {
        guard let offer = herdrOffer else { return [] }
        let first = offer.programs.first?.template
        let main = keptMainBot.map { $0.template ?? first } ?? mainBot.template
        let names = herdrBots.map { $0.name.lowercased() } + [mainBotName.lowercased()]
        return offer.others(than: main, taken: Set(herdrBots.compactMap { $0.template ?? first }), names: Set(names))
    }
    /// The ticked programs, in the server's order.
    var moreChosen: [HerdrProgram] { moreChoices.filter { moreBots.contains($0.template) } }
    /// The step whose button creates the bots: the main bot when the server has no other program to offer.
    var isLastWizardStep: Bool { step == .moreBots || (step == .mainBot && moreChoices.isEmpty) }

    /// S3-OC's Test reads "Test again" after the Gateway asked for approval.
    var awaitsPairing: Bool { if case .pairingRequired = openClawOutcome { true } else { false } }
    /// The request id for the approve command, when the Gateway sent one.
    var pairingRequestId: String? { if case .pairingRequired(let id) = openClawOutcome { id } else { nil } }
    var openClawFailure: String? { if case .failed(let line) = openClawOutcome { line } else { nil } }
    var openClawAgents: [OpenClawAgent] { if case .connected(let agents) = openClawOutcome { agents } else { [] } }

    /// S4's rows for the software chosen.
    var choices: [SetupChoice] {
        guard software != .openClaw else { return openClawAgents.map { SetupChoice(id: $0.id, name: $0.displayName) } }
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
            switch picked { case .hermes: go(.address); case .openClaw: go(.openClaw); case .herdr: herdrOutcome = nil; herdrTested = nil; go(.herdr) }
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
            software = .herdr; place = kind; herdr = HerdrServerDraft(kind: kind); herdrOutcome = nil; herdrTested = nil
            go(.herdr)
        case .herdrTest(let outcome, let bots):
            herdrOutcome = outcome; herdrTested = herdr; herdrBots = bots
            guard let offer = herdrOffer, !offer.programs.isEmpty else {
                // A saved server that cannot be used shows its own Connect screen, with the reason.
                if step == .mainBot || step == .moreBots { history = [.welcome]; step = .herdr }
                return
            }
            mainBot.begin(offer: offer, bots: bots); moreBots = []
        case .advance:
            if step == .herdr, herdrReady { go(.mainBot) }
            else if step == .mainBot, mainBotReady, !moreChoices.isEmpty { moreBots.formIntersection(moreChoices.map(\.template)); go(.moreBots) }
        case .add(let count, let first): addedCount = count; firstAdded = first; history = []; step = .done
        case .back:
            guard canGoBack, let previous = history.popLast() else { return }
            step = previous
            // Back to the choice undoes S3-OC's Test (its Gateway is forgotten by the window).
            if previous == .software || previous == .welcome { openClawOutcome = nil; openClawGatewayID = nil; herdrOutcome = nil; herdrTested = nil }
        }
    }

    /// Ticks every found agent that is not already added; called when S4 opens.
    mutating func preselect(alreadyAdded: Set<String>) {
        chosen = Set(choices.map(\.id)).subtracting(alreadyAdded)
    }

    private mutating func go(_ next: Step) { history.append(step); step = next }
}
