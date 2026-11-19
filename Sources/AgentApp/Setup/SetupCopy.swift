import Foundation

/// Every visible string of the setup window's Connect screen and of the server fields Settings shows too, in plain
/// words. The wizard's own words (its steps, results and the bots it creates) are in `WizardCopy`. Commands are
/// shown verbatim in monospace and are not copy.
enum SetupCopy {
    static let windowTitle = "Set up"
    static let back = "Back"
    static let cancel = "Cancel"
    static let sampleLink = "Look around with sample bots"
    static let test = "Connect"
    static let testing = "Connecting…"
    static let testAgain = "Try again"
    static let failed = "Your setup could not be saved, so nothing was changed. Try again."
    static let thisMac = "this Mac"

    // The ways to reach a server and the fields of its Connect screen.
    static let herdrLocalTitle = "This Mac"
    static let herdrSSHTitle = "A server"
    static let herdrAddressTitle = "A server by address"
    static let herdrReadyMadeTitle = "Get a ready-made server from us"
    static let herdrReadyMadeDetail = "We set it up and run it for you."
    static let herdrNameLabel = "Name"
    static let herdrOptional = "Optional"
    static let herdrPortLabel = "Port"
    static let herdrServerLabel = "Server"
    static let herdrServerPrompt = "my-server or user@my-server"
    static let herdrKeyFileLabel = "SSH key file"
    static let herdrKeyFilePrompt = "Optional, for example ~/.ssh/id_ed25519"
    static let herdrChoose = "Choose…"
    static let herdrAddressLabel = "Address"
    static let herdrAddressPrompt = "http://127.0.0.1:8787"
    static let herdrAccessKeyLabel = "Access key"
    static let herdrLocalKeyPrompt = "Read from this Mac"
    static let herdrSSHKeyPrompt = "Read from the server"
    static var herdrLocalCaption: String { "Leave the access key empty: \(AppConstants.name) finds it on this Mac." }
    static var herdrSSHKeyCaption: String { "Leave the access key empty: \(AppConstants.name) finds it on the server." }
    static var herdrAddressCaption: String {
        "The server only answers on its own computer, so forward its port to this Mac first (the same port number on both ends). Or go back and choose “A server”, and \(AppConstants.name) does that for you."
    }
    static func herdrNothingHere(port: Int) -> String { "This Mac is not set up to run bots yet (nothing answers on port \(port))." }
    static var herdrStartHelp: String { "Open the setup window (Settings → Set up…) and choose This Mac: \(AppConstants.name) sets it up for you." }

    // Settings → Servers, This Mac: taking the service away again.
    static var localServiceTitle: String { "The \(AppConstants.name) service on this Mac" }
    static let localServiceDetail = "Runs your bots in the background and starts when you log in."
    static let localRemove = "Stop and Remove…"
    static var localRemoveQuestion: String { "Stop the \(AppConstants.name) service and remove it from this Mac?" }
    static let localRemoveDetail = "Your bots on this Mac stop answering until you set it up again, and their running AI programs are ended. What your AIs were told to trust for your bots is taken back. Your conversations, your bots’ files and Herdr Core stay."
    static let localRemoveConfirm = "Stop and Remove"
    static let localRemoving = "Removing…"
    static let localRemoved = "Removed from this Mac"
    static func localKept(_ line: String) -> String { "Kept: \(line)" }

    /// Static strings only; the functions are checked with sample arguments by the tests.
    static var all: [String] { [windowTitle, back, cancel, sampleLink, test, testing, testAgain, failed, thisMac] + herdrScreen + ManagedHosting.all }
    static var herdrScreen: [String] {
        [herdrLocalTitle, herdrSSHTitle, herdrAddressTitle, herdrReadyMadeTitle, herdrReadyMadeDetail, herdrNameLabel, herdrOptional, herdrPortLabel, herdrServerLabel,
         herdrServerPrompt, herdrKeyFileLabel, herdrKeyFilePrompt, herdrChoose, herdrAddressLabel, herdrAddressPrompt,
         herdrAccessKeyLabel, herdrLocalKeyPrompt, herdrSSHKeyPrompt, herdrLocalCaption, herdrSSHKeyCaption, herdrAddressCaption,
         herdrNothingHere(port: 8787), herdrStartHelp, localServiceTitle, localServiceDetail, localRemove, localRemoveQuestion, localRemoveDetail, localRemoveConfirm,
         localRemoving, localRemoved, localKept("Herdr Core.")]
    }
}
