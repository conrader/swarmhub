import Foundation

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

/// The setup window's steps as a pure state machine: a wizard of four steps: where bots run (`welcome`), Connect
/// (`herdr`), the main bot (`mainBot`) and the optional bots (`moreBots`). No step writes anything: the last button
/// creates everything at once (`AppStore.commitSetupWizard`) and the window closes on the main bot's chat, so closing
/// it earlier leaves nothing behind. A server that was set up before starts at the main bot.
struct SetupFlow: Equatable {
    enum Step: String, CaseIterable, Equatable { case welcome, herdr, mainBot, moreBots, projects }
    enum Action: Equatable {
        /// Where it runs was chosen on Welcome; Connect's Test finished (`bots`: the bots already on that server);
        /// Continue was pressed on Connect or on the main bot.
        case pickHerdr(HerdrServer.Kind), herdrTest(HerdrSetupOutcome, bots: [HerdrSetupBot] = []), advance
        case back
        /// This Mac is being set up, or no longer (`nil`); what the service on this Mac says about it; and how the
        /// check of one of its AIs stands.
        case localSetup(HerdrLocalSetup?), localReport(HerdrLocalReport?), aiCheck(HerdrAICheck)
    }

    private(set) var step: Step = .welcome
    private(set) var history: [Step] = []
    /// Where bots run, as selected on Welcome (This Mac unless the person picks another).
    var place = HerdrServer.Kind.local
    /// The Herdr screen's fields, its last Test and the fields that Test ran with: a result counts while they are unchanged.
    var herdr = HerdrServerDraft()
    private(set) var herdrOutcome: HerdrSetupOutcome?
    private(set) var herdrTested: HerdrServerDraft?
    /// The bots already on the tested server.
    private(set) var herdrBots: [HerdrSetupBot] = []
    /// This Mac only. Nothing answers here: getting it ready is offered, under way, or stopped with the reason.
    private(set) var localSetup: HerdrLocalSetup?
    /// This Mac only: setting it up also answers, for the person, what an AI asks the first time. On unless they turn it off.
    var localAnswers = true
    /// This Mac only: what its service says is installed, and which AI programs it did not find.
    private(set) var localReport: HerdrLocalReport?
    /// This Mac only: whether each AI can take a message, or waits for an answer first.
    private(set) var aiChecks: [HerdrAICheck] = []
    /// An AI waits for the person's answer in its terminal.
    var aiNeedsAnswer: Bool { aiChecks.contains { if case .asks = $0.state { true } else { false } } }
    var aiChecking: Bool { aiChecks.contains { $0.state == .checking } }
    var mainBot = HerdrMainBotDraft()
    /// Templates ticked on "More bots"; none to begin with, so nothing is added unasked.
    var moreBots: Set<String> = []
    /// The projects on other servers chosen for the main bot on "Where are your projects?"; none to begin with.
    var mainProjects: [HerdrBotProject] = []

    /// A Herdr server that is already set up: Connect is skipped and the window opens on the main bot, which waits for
    /// what the server offers (`herdrTest`). Back leads to where bots run.
    init(saved server: HerdrServer) {
        herdr = HerdrServerDraft(server: server); place = server.kind
        step = .mainBot; history = [.welcome]
    }

    init() {}

    /// Back exists on every step but the first.
    var canGoBack: Bool { !history.isEmpty }

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
    /// "Where are your projects?" is a step on a server whose workspace can add project servers. It is optional: its
    /// button is the wizard's last, whether or not anything was added.
    var offersProjects: Bool { herdrOffer?.projectServers == true }
    /// The step whose button creates the bots: the projects where they are offered; otherwise the optional bots, or
    /// the main bot when the server has no other program to offer.
    var isLastWizardStep: Bool {
        if offersProjects { return step == .projects }
        return step == .moreBots || (step == .mainBot && moreChoices.isEmpty)
    }
    /// How many steps the wizard has on this server, for the dots under its content.
    var stepCount: Int { 3 + (herdrOffer != nil && moreChoices.isEmpty ? 0 : 1) + (offersProjects ? 1 : 0) }
    /// Which of them is showing.
    var stepIndex: Int {
        switch step {
        case .welcome: 0
        case .herdr: 1
        case .mainBot: 2
        case .moreBots: 3
        case .projects: stepCount - 1
        }
    }

    mutating func apply(_ action: Action) {
        switch action {
        case .pickHerdr(let kind):
            place = kind; herdr = HerdrServerDraft(kind: kind); herdrOutcome = nil; herdrTested = nil
            localSetup = nil; localReport = nil; aiChecks = []
            go(.herdr)
        case .herdrTest(let outcome, let bots):
            herdrOutcome = outcome; herdrTested = herdr; herdrBots = bots
            // A new answer from the server starts the checks of its AIs afresh.
            aiChecks = []
            if case .nothingHere = outcome {} else { localSetup = nil }
            guard let offer = herdrOffer, !offer.programs.isEmpty else {
                // A saved server that cannot be used shows its own Connect screen, with the reason.
                if step == .mainBot || step == .moreBots || step == .projects { history = [.welcome]; step = .herdr }
                return
            }
            mainBot.begin(offer: offer, bots: bots); moreBots = []; mainProjects = []
        case .advance:
            if step == .herdr, herdrReady { go(.mainBot) }
            else if step == .mainBot, mainBotReady, !moreChoices.isEmpty { moreBots.formIntersection(moreChoices.map(\.template)); go(.moreBots) }
            else if step == .mainBot, mainBotReady, offersProjects { go(.projects) }
            else if step == .moreBots, offersProjects { go(.projects) }
        case .back:
            guard canGoBack, let previous = history.popLast() else { return }
            step = previous
            // Back to where bots run undoes Connect's Test.
            if previous == .welcome { herdrOutcome = nil; herdrTested = nil; localSetup = nil; localReport = nil; aiChecks = [] }
        case .localSetup(let phase): localSetup = phase
        case .localReport(let report): localReport = report
        case .aiCheck(let check):
            if let index = aiChecks.firstIndex(where: { $0.id == check.id }) { aiChecks[index] = check } else { aiChecks.append(check) }
        }
    }

    private mutating func go(_ next: Step) { history.append(step); step = next }
}
