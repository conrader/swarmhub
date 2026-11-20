import Foundation

/// Every visible string of the setup wizard's own steps: where bots run, the result of Connect, the main bot and
/// the optional bots. The fields of the Connect step keep their words in `SetupCopy` (they are shared with Settings).
/// The wizard says "bot" (a "helper" is something a bot starts), "AI" for the agent program a bot runs on and "access
/// key" for the server's secret. It names no AI and no model itself: those names come from the server.
enum WizardCopy {
    /// The four steps, as the strip at the top of the window names them.
    static let addHost = "Add a host"
    static let steps = ["Where", "Connect", "Main bot", "More bots"]
    /// The optional step after the bots, on a server that can add project servers.
    static let projectsStep = "Projects"
    /// `name`: the step's own name where it is not one of the four (the projects, which come last wherever they are offered).
    static func stepLabel(_ index: Int, of count: Int = steps.count, name: String? = nil) -> String { "Step \(index + 1) of \(count): \(name ?? steps[min(max(index, 0), steps.count - 1)])" }
    static let next = "Continue"
    static let chooseAvailable = "Use an available agent instead"
    static func missingPrograms(_ programs: [String]) -> String {
        let names = programs.map { ["claude": "Claude Code", "opencode": "OpenCode", "codex": "Codex"][$0] ?? $0 }.joined(separator: " and ")
        return "Install and sign in to \(names) on this Mac, then check again."
    }
    static let allowHelpers = "Give this bot instructions for starting helpers"

    // 1 Where bots run. The four places keep the titles Settings uses for them (`SetupCopy.herdrLocalTitle` and the rest).
    static var welcomeTitle: String { "Welcome to \(AppConstants.name)" }
    static let welcomeIntro = "Chat with your own team of AI bots. They work for you on a computer you choose."
    static let whereTitle = "Where should your bots run?"
    static let localDetail = "Your bots work on this computer."
    static var sshDetail: String { "\(AppConstants.name) connects with your SSH login." }
    static let addressDetail = "For a server whose port you already forwarded to this Mac."
    /// The fold on the first step that holds the way few people need.
    static let otherWays = "Advanced"

    // 2 Connect
    static let localHeader = "This Mac"
    static let sshHeader = "Your server"
    static let addressHeader = "Your server"
    static let localIntro = "Checking that this Mac is ready to run your bots."
    static let localSetupIntro = "Set it up once, and your bots work right here."
    static let sshIntro = "Use the same server name or SSH login you use in Terminal."
    static let addressIntro = "Give its address and access key."
    static let details = "Connection details"
    static func connected(_ name: String) -> String { "\(name) is ready" }
    static let notConnected = "Not connected yet"
    static let notReady = "Connected, but not ready yet"
    static let copy = "Copy"
    static let copied = "Copied"
    static func canRun(_ names: String, count: Int) -> String { "Your bots can run on \(names)." }
    static func nothingHere(port: Int) -> String { "This Mac is not set up to run bots yet" }
    static let nothingElse = "Or go back and choose a server that is already set up."

    // 2 Connect, on a Mac where nothing runs yet: the app sets it up after one clear yes.
    static var setUpTitle: String { "\(AppConstants.name) installs what your bots need to run here" }
    static var serviceItem: String { "The \(AppConstants.name) service" }
    static let serviceDetail = "Runs your bots, also while the app is closed. Starts when you log in. In your home folder, in .local/bin."
    static let coreItem = "Herdr Core"
    static let coreDetail = "Keeps each bot’s AI program running. Downloaded from Herdr (herdr.dev) and checked before it is installed."
    static let coreThere = "Already on this Mac."
    static let folderItem = "A folder for your bots’ work"
    static let folderDetail = "swarmhub-agents, in your home folder."
    static let answersItem = "Answer my AIs’ first questions for me"
    static var answersDetail: String {
        "Each AI asks once whether it may work in your bots’ folder and run the commands \(AppConstants.name) gives it to show its steps and save its replies. \(AppConstants.name) answers yes to these two for you. An AI also uses settings files it finds in a folder it trusts. Anything else it asks stays yours to answer."
    }
    static let whatWasDone = "What was set up"
    static let setUpNote = "Your bots use the AI programs already on this Mac. You can remove all of this later in Settings."
    static let setUp = "Set Up This Mac"
    static let settingUp = "Setting Up…"
    static var fetching: String { "Downloading the \(AppConstants.name) service…" }
    static let fetchingDetail = "It is checked against the release’s signature before it is used."
    static let installing = "Setting up this Mac…"
    static let installingDetail = "The service sets up its files and downloads Herdr Core if this Mac needs it."
    static let setUpFailed = "This Mac could not be set up"
    /// The usual port already answers for something else (a forward to a server): another one was taken, unasked.
    static func portMoved(from: Int, to: Int) -> String { "Port \(from) on this Mac is already in use, so \(AppConstants.name) uses port \(to) here." }
    /// A port another program holds: the fold with the port is where to change it.
    static func portBusy(_ port: Int) -> String { "Another program on this Mac already uses port \(port). Open Connection details below, choose another port (for example \(port + 1)), and try again." }

    // 2 Connect, once this Mac answers: whether each AI can take a message.
    static let aiTitle = "Your AIs"
    static let aiChecking = "Checking…"
    static let aiReady = "Ready"
    static let aiAsks = "Has a question for you"
    static func aiAsksDetail(_ name: String) -> String { "\(name) asks this once, in its own window, and only you can answer. Your bots on \(name) wait until you have." }
    static let aiAnswer = "Answer in Terminal"
    static let aiAgain = "Check Again"
    static let aiFailed = "Could not be started"
    static func aiMissing(_ name: String) -> String { "\(name) is not on this Mac" }
    static let noAIsTitle = "No AI program was found on this Mac"
    static let noAIsDetail = "Your bots need at least one. Install one, sign in to it, then press Try again."

    // 3 The main bot
    static let mainTitle = "Your main bot"
    static let mainIntro = "The bot you talk to first. It can set up other bots for you."
    static func reading(_ server: String) -> String { "Checking \(server)…" }
    static let mainChoice = "Main bot"
    static let mainNew = "A new bot"
    static func mainExisting(_ name: String, isMain: Bool) -> String { isMain ? "\(name) (the main bot now)" : name }
    /// Under the name of the server's main bot, where the bots of a server are offered as tiles.
    static let mainNow = "The main bot now"
    /// Under the model a bot starts on unless another is chosen.
    static let defaultNote = "Default"
    static let name = "Name"
    static let instructions = "Instructions"
    static let instructionsPrompt = "Optional: what it should know or do"
    static let avatar = "Avatar"
    static let avatarHelp = "Choose its avatar"
    static let avatarHint = "Choose a shape and a color."
    static let program = "AI"
    static let model = "Model"
    static func defaultModel(_ name: String) -> String { "\(name) (default)" }
    static func runsOn(_ server: String) -> String { "You can change all of this later." }
    static func keeps(_ name: String, server: String, isMain: Bool) -> String {
        isMain ? "\(name) stays your main bot on \(server), just as it is."
            : "\(name) becomes your main bot on \(server). Nothing else about it changes."
    }
    static let nameMissing = "Give your main bot a name."
    static func nameTaken(_ name: String) -> String { "You already have a bot named \(name) here. Choose another name, or pick that bot above." }
    static let programMissing = "Choose an AI."
    /// Only a suggestion: the field is editable.
    static let suggestedName = "Jarvis"

    // 4 More bots
    static let moreTitle = "More bots"
    static func moreIntro(server: String, main: String) -> String {
        "Optional. Add a bot for another AI now, or ask \(main) for more bots later."
    }
    static func moreDetail(_ program: String, model: String?) -> String {
        model.map { "Starts on \($0)." } ?? "Picks its own model."
    }
        static func create(_ name: String) -> String { "Create \(name)" }
    static let createMain = "Create main bot"
    static func createBots(_ count: Int) -> String { "Create \(count) bots" }
    static func addBots(_ count: Int) -> String { count == 1 ? "Add 1 bot" : "Add \(count) bots" }
    static let finish = "Finish"

    // 5 Projects on other servers (optional)
    static let projectsTitle = "Where are your projects?"
    static func projectsIntro(server: String, main: String) -> String {
        "Optional. If your code or files live on another server, add it here and \(main) can work on them there."
    }
    static let projectsSkip = "You can skip this and add a server later in Settings."
    static let projectsReading = "Checking for project servers…"
    static let projectsUnavailable = "Project servers cannot be added here yet"
    static let projectsFirst = "Name a first project"
    static func projectsFor(_ main: String) -> String { "Projects \(main) may use" }
    static func projectsMayUse(_ main: String, _ project: String) -> String { "\(main) may use \(project)" }
    static let projectsAnother = "Add another project…"

    // After the wizard: under the composer of the chat it ends in.
    static func firstReply(_ name: String) -> String { "\(name) starts with your first message, so the first reply takes a little longer." }

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        steps + [stepLabel(0), next, welcomeTitle, welcomeIntro, whereTitle, localDetail, sshDetail, addressDetail, otherWays,
                 localHeader, sshHeader, addressHeader, localIntro, localSetupIntro, sshIntro, addressIntro, details, connected("This Mac"), canRun("One", count: 1), canRun("One and Two", count: 2),
                 nothingHere(port: 8787), nothingElse, setUpTitle, serviceItem, serviceDetail, coreItem, coreDetail, coreThere, folderItem, folderDetail, answersItem, answersDetail, whatWasDone, setUpNote,
                 setUp, settingUp, fetching, fetchingDetail, installing, installingDetail, setUpFailed, portBusy(8787), portMoved(from: 8787, to: 8788), aiTitle, aiChecking, aiReady, aiAsks, aiAsksDetail("One"),
                 aiAnswer, aiAgain, aiFailed, aiMissing("One"), noAIsTitle, noAIsDetail, mainTitle, mainIntro, reading("This Mac"), mainChoice, mainNew, mainExisting("Ada", isMain: true),
                 mainExisting("Ada", isMain: false), name, instructions, instructionsPrompt, avatar, avatarHelp, program, model, defaultModel("One"), runsOn("This Mac"),
                 keeps("Ada", server: "This Mac", isMain: true), keeps("Ada", server: "This Mac", isMain: false), nameMissing, nameTaken("Ada"), programMissing, suggestedName,
                 moreTitle, moreIntro(server: "This Mac", main: "Ada"), moreDetail("One", model: "First"), moreDetail("One", model: nil), create("Ada"), createMain, createBots(2),
                 addBots(1), addBots(2), finish, firstReply("Ada"), avatarHint, notConnected, notReady, copy, copied, mainNow, defaultNote,
                 projectsStep, stepLabel(4, of: 5, name: projectsStep), projectsTitle, projectsIntro(server: "This Mac", main: "Ada"), projectsSkip, projectsReading, projectsUnavailable,
                 projectsFirst, projectsFor("Ada"), projectsMayUse("Ada", "shop"), projectsAnother]
    }
}
