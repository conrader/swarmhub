import Foundation

/// Every visible string of the setup wizard's own steps: where bots run, the result of Connect, the main bot and
/// the optional bots. The fields of the Connect step keep their words in `SetupCopy` (they are shared with Settings).
/// The wizard says "bot" (a "helper agent" is something a bot starts, and an "agent program" is what a bot runs on),
/// "access key" for the server's secret, and names no agent program and no model: those names come from the server.
enum WizardCopy {
    /// The four steps, as the strip at the top of the window names them.
    static let steps = ["Where", "Connect", "Main bot", "More bots"]
    /// The optional step after the bots, on a server that can add project servers.
    static let projectsStep = "Projects"
    /// `name`: the step's own name where it is not one of the four (the projects, which come last wherever they are offered).
    static func stepLabel(_ index: Int, of count: Int = steps.count, name: String? = nil) -> String { "Step \(index + 1) of \(count): \(name ?? steps[min(max(index, 0), steps.count - 1)])" }
    static let next = "Continue"

    // 1 Where bots run. The four places keep the titles Settings uses for them (`SetupCopy.herdrLocalTitle` and the rest).
    static var welcomeTitle: String { "Welcome to \(AppConstants.name)" }
    static var welcomeIntro: String { "\(AppConstants.name) is where you chat with your bots: AI agents that work for you on a computer you choose." }
    static let whereTitle = "Where should your bots run?"
    static let localDetail = "Your bots work on this computer."
    static var sshDetail: String { "Give its name and login; \(AppConstants.name) opens the connection itself." }
    static let addressDetail = "For a server whose port is already forwarded to this Mac."

    // 2 Connect
    static let localHeader = "This Mac"
    static let sshHeader = "Your server"
    static let addressHeader = "Your server's address and access key"
    static var localIntro: String { "\(AppConstants.name) looks on this Mac for Herdr Core, the program that runs your bots." }
    static var sshIntro: String { "\(AppConstants.name) logs in to your server and looks there for Herdr Core, the program that runs your bots." }
    static let addressIntro = "The server must run Herdr Core, the program that runs your bots."
    static let details = "Connection details"
    static func connected(_ name: String) -> String { "Connected to \(name)." }
    static let notConnected = "Not connected yet"
    static let notReady = "Connected, but not ready"
    static let copy = "Copy"
    static let copied = "Copied"
    static func canRun(_ names: String, count: Int) -> String { count == 1 ? "It can run one agent program: \(names)." : "It can run \(count) agent programs: \(names)." }
    static func nothingHere(port: Int) -> String { "Nothing is running on this Mac yet: nothing answers at 127.0.0.1:\(port)." }
    static var nothingHelp: String {
        "Bots need Herdr Core and the \(AppConstants.name) service running on the computer they work on. \(AppConstants.name) does not include or install them yet, so start both yourself, then press Test again."
    }
    static var nothingCommand: String { "With a copy of the \(AppConstants.name) source, this starts the service beside a running Herdr Core:" }
    static let nothingElse = "No Herdr Core on this Mac? Go back and choose a server that has it."

    // 3 The main bot
    static let mainTitle = "Your main bot"
    static let mainIntro = "Each server has one main bot. It can create other bots for you, and every other bot asks it."
    static func reading(_ server: String) -> String { "Reading what \(server) can run…" }
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
    static let program = "Agent program"
    static let model = "Model"
    static func defaultModel(_ name: String) -> String { "\(name) (default)" }
    static func runsOn(_ server: String) -> String { "It runs on \(server). You can change all of this later in its settings." }
    static func keeps(_ name: String, server: String, isMain: Bool) -> String {
        isMain ? "\(name) stays the main bot of \(server), with its instructions, agent program and model."
            : "\(name) becomes the main bot of \(server). Its instructions, agent program and model stay as they are."
    }
    static let nameMissing = "Give your main bot a name."
    static func nameTaken(_ name: String) -> String { "A bot named \(name) is already on this server. Choose another name, or choose that bot under Main bot." }
    static let programMissing = "Choose an agent program."
    /// Only a suggestion: the field is editable.
    static let suggestedName = "Jarvis"

    // 4 More bots
    static let moreTitle = "More bots"
    static func moreIntro(server: String, main: String) -> String {
        "Optional. \(server) can run other agent programs too. Tick one to add a bot for it now; \(main) can also create bots for you later."
    }
    static func moreDetail(_ program: String, model: String?) -> String {
        model.map { "A bot named \(program), starting on \($0)." } ?? "A bot named \(program); its agent program picks the model."
    }
    static let moreNone = "Nothing is added unless you tick it."
    static func create(_ name: String) -> String { "Create \(name)" }
    static let createMain = "Create main bot"
    static func createBots(_ count: Int) -> String { "Create \(count) bots" }
    static func addBots(_ count: Int) -> String { count == 1 ? "Add 1 bot" : "Add \(count) bots" }
    static let finish = "Finish"
    static func titleOnHerdr(_ program: String) -> String { "\(program) on Herdr" }

    // 5 Projects on other servers (optional)
    static let projectsTitle = "Where are your projects?"
    static func projectsIntro(server: String, main: String) -> String {
        "Optional. If your projects are on another server than \(server), add that server here and \(main) can work on them there."
    }
    static let projectsSkip = "Nothing to add? Go on: this step changes nothing unless you add a server, and you can add one later in Settings."
    static let projectsReading = "Reading the project servers…"
    static let projectsUnavailable = "Project servers cannot be set up here"
    static let projectsFirst = "Name a first project"
    static func projectsFor(_ main: String) -> String { "Projects \(main) may use" }
    static func projectsMayUse(_ main: String, _ project: String) -> String { "\(main) may use \(project)" }
    static let projectsAnother = "Add another project…"

    // After the wizard: under the composer of the chat it ends in.
    static func firstReply(_ name: String) -> String { "Your first message starts \(name)'s agent, so the first reply takes a little longer." }

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        steps + [stepLabel(0), next, welcomeTitle, welcomeIntro, whereTitle, localDetail, sshDetail, addressDetail,
                 localHeader, sshHeader, addressHeader, localIntro, sshIntro, addressIntro, details, connected("This Mac"), canRun("One", count: 1), canRun("One and Two", count: 2),
                 nothingHere(port: 8787), nothingHelp, nothingCommand, nothingElse, mainTitle, mainIntro, reading("This Mac"), mainChoice, mainNew, mainExisting("Ada", isMain: true),
                 mainExisting("Ada", isMain: false), name, instructions, instructionsPrompt, avatar, avatarHelp, program, model, defaultModel("One"), runsOn("This Mac"),
                 keeps("Ada", server: "This Mac", isMain: true), keeps("Ada", server: "This Mac", isMain: false), nameMissing, nameTaken("Ada"), programMissing, suggestedName,
                 moreTitle, moreIntro(server: "This Mac", main: "Ada"), moreDetail("One", model: "First"), moreDetail("One", model: nil), moreNone, create("Ada"), createMain, createBots(2),
                 addBots(1), addBots(2), finish, titleOnHerdr("One"), firstReply("Ada"), avatarHint, notConnected, notReady, copy, copied, mainNow, defaultNote,
                 projectsStep, stepLabel(4, of: 5, name: projectsStep), projectsTitle, projectsIntro(server: "This Mac", main: "Ada"), projectsSkip, projectsReading, projectsUnavailable,
                 projectsFirst, projectsFor("Ada"), projectsMayUse("Ada", "shop"), projectsAnother]
    }
}
