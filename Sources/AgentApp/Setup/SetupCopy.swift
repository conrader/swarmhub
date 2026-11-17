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
    static let herdrServerPrompt = "my-server.example.com"
    static let herdrLoginLabel = "Login name"
    static let herdrKeyFileLabel = "SSH key file"
    static let herdrKeyFilePrompt = "Optional, for example ~/.ssh/id_ed25519"
    static let herdrChoose = "Choose…"
    static let herdrAddressLabel = "Address"
    static let herdrAddressPrompt = "http://127.0.0.1:8787"
    static let herdrAccessKeyLabel = "Access key"
    static let herdrLocalKeyPrompt = "Read from this Mac"
    static let herdrSSHKeyPrompt = "Read from the server"
    static var herdrLocalCaption: String { "Leave the access key empty: \(AppConstants.name) finds it on this Mac." }
    static var herdrSSHCaption: String {
        "\(AppConstants.name) keeps the connection open for you. It never copies your key file; one with a passphrase must be unlocked first (ssh-add)."
    }
    static var herdrSSHKeyCaption: String { "Leave the access key empty: \(AppConstants.name) finds it on the server." }
    static var herdrAddressCaption: String {
        "The server only answers on its own computer, so forward its port to this Mac first (the same port number on both ends). Or go back and choose “A server”, and \(AppConstants.name) does that for you."
    }
    static func herdrNothingHere(port: Int) -> String { "This Mac is not set up to run bots yet (nothing answers on port \(port))." }
    static var herdrStartHelp: String { "Start Herdr Core and the \(AppConstants.name) service on this Mac, then try again:" }

    /// Static strings only; the functions are checked with sample arguments by the tests.
    static var all: [String] { [windowTitle, back, cancel, sampleLink, test, testing, testAgain, failed, thisMac] + herdrScreen + ManagedHosting.all }
    static var herdrScreen: [String] {
        [herdrLocalTitle, herdrSSHTitle, herdrAddressTitle, herdrReadyMadeTitle, herdrReadyMadeDetail, herdrNameLabel, herdrOptional, herdrPortLabel, herdrServerLabel,
         herdrServerPrompt, herdrLoginLabel, herdrKeyFileLabel, herdrKeyFilePrompt, herdrChoose, herdrAddressLabel, herdrAddressPrompt,
         herdrAccessKeyLabel, herdrLocalKeyPrompt, herdrSSHKeyPrompt, herdrLocalCaption, herdrSSHCaption, herdrSSHKeyCaption, herdrAddressCaption,
         herdrNothingHere(port: 8787), herdrStartHelp]
    }
}
