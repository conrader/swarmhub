import Foundation

/// Every visible string of the setup window's Connect screen and of the server fields Settings shows too, in plain
/// words. The wizard's own words (its steps, results and the bots it creates) are in `WizardCopy`. Commands are
/// shown verbatim in monospace and are not copy.
enum SetupCopy {
    static let windowTitle = "Set up"
    static let back = "Back"
    static let cancel = "Cancel"
    static let sampleLink = "Look around with sample agents"
    static let test = "Test"
    static let testing = "Testing…"
    static let testAgain = "Test again"
    static let failed = "Could not finish. Nothing was changed."
    static let thisMac = "this Mac"

    // The ways to reach a server and the fields of its Connect screen.
    static let herdrLocalTitle = "This Mac"
    static let herdrSSHTitle = "A server I reach over SSH"
    static let herdrAddressTitle = "A server by address and access key"
    static let herdrReadyMadeTitle = "Get a ready-made server from us"
    static let herdrReadyMadeDetail = "Set up and run for you. Not available yet."
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
    static var herdrLocalCaption: String { "Leave the access key empty: \(AppConstants.name) reads the one Herdr wrote on this Mac." }
    static var herdrSSHCaption: String {
        "\(AppConstants.name) runs ssh for you and reopens the connection when it drops, so you never forward a port by hand. It remembers where the key file is and never copies it. A key file with a passphrase must be unlocked first (ssh-add)."
    }
    static let herdrSSHKeyCaption = "Leave the access key empty to read it from the server."
    static var herdrAddressCaption: String {
        "Herdr answers only on its own computer. Forward its port to this Mac first, with the same port number on both ends, or go back and choose SSH so \(AppConstants.name) does it."
    }
    static func herdrNothingHere(port: Int) -> String { "Nothing answers on this Mac at 127.0.0.1:\(port)." }
    static var herdrStartHelp: String { "Herdr is not built into \(AppConstants.name) yet. Start Herdr Core and its \(AppConstants.name) service on this Mac, then press Test again:" }

    /// Static strings only; the functions are checked with sample arguments by the tests.
    static var all: [String] { [windowTitle, back, cancel, sampleLink, test, testing, testAgain, failed, thisMac] + herdrScreen + ManagedHosting.all }
    static var herdrScreen: [String] {
        [herdrLocalTitle, herdrSSHTitle, herdrAddressTitle, herdrReadyMadeTitle, herdrReadyMadeDetail, herdrNameLabel, herdrOptional, herdrPortLabel, herdrServerLabel,
         herdrServerPrompt, herdrLoginLabel, herdrKeyFileLabel, herdrKeyFilePrompt, herdrChoose, herdrAddressLabel, herdrAddressPrompt,
         herdrAccessKeyLabel, herdrLocalKeyPrompt, herdrSSHKeyPrompt, herdrLocalCaption, herdrSSHCaption, herdrSSHKeyCaption, herdrAddressCaption,
         herdrNothingHere(port: 8787), herdrStartHelp]
    }
}
