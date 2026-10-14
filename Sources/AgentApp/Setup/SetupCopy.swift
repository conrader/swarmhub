import Foundation

/// Every visible string of the setup window (P21 Part C), in plain words. Banned here (a test checks `all`):
/// technical words such as the server's internal names, and "bot" (the wizard says "agents", D12). "Box",
/// "address" and "key" are the three defined terms; Hermes and OpenClaw appear only in `softwareNames` (the S1 line,
/// the S2 cards and the S3-OC screen, P25 D6). Commands are shown verbatim in monospace and are not copy.
enum SetupCopy {
    static let windowTitle = "Set up"
    static let back = "Back"
    static let cancel = "Cancel"
    static let skip = "Skip for now"
    static let sampleLink = "Look around with sample agents"

    // S1 Welcome
    static var welcomeTitle: String { "Let's connect \(AppConstants.name) to your agents." }
    static let connectCardTitle = "Connect my existing box"
    /// The one place "box" is defined.
    static let connectCardDetail = "Your box is the computer or server where your agents run."
    static let softwareLine = "Works with Hermes and OpenClaw."

    // S2 Which software
    static let softwareTitle = "Which software runs your agents?"
    static let hermesCardTitle = "Hermes"
    static let hermesCardDetail = "Connect with the address and key of your box."
    static let openClawCardTitle = "OpenClaw"
    static let openClawCardDetail = "Connect this Mac to your OpenClaw and approve it there once."

    // S3-OC OpenClaw address and key
    static let openClawTitle = "Where is your OpenClaw?"
    static let openClawAddressLabel = "Address"
    static let openClawKeyPrompt = "Optional"
    /// The one place OpenClaw's own name for the key appears (P25 D6).
    static let openClawKeyCaption = "Your key: the first command below shows it on your OpenClaw computer (OpenClaw calls it the Gateway token). Leave it empty when Tailscale or a proxy signs this Mac in."
    static let openClawPlainToggle = "Allow plain ws:// on my private network"
    static let openClawMore = "More"
    static let openClawDeviceName = "Device name"
    static let openClawKeepKey = "Keep the key after pairing"
    static let openClawHelpKey = "Show the key, on your OpenClaw computer:"
    static let openClawHelpTunnel = "OpenClaw on another computer? Open a tunnel, then use \(OpenClawCopy.tunnelURL) (no approval needed):"
    static let openClawHelpApprove = "Otherwise approve this Mac on your OpenClaw computer:"
    static let openClawPairing = "Approve this Mac on your OpenClaw computer, then press Test again."
    static let testAgain = "Test again"
    static func openClawFound(_ count: Int) -> String { "Connected to OpenClaw. Found \(count == 1 ? "1 agent" : "\(count) agents")." }
    static let openClawNoAgents = "OpenClaw answered but offered no agents to add."

    // S3 Address and key
    static let addressTitle = "Where are your agents?"
    static let addressLabel = "Address of your box"
    static let addressPlaceholder = "https://my-box.example.com"
    static let keyLabel = "Key"
    static let keyCaption = "Stored on this Mac; never shown again."
    static let keepKeyCaption = "Leave empty to keep the key saved on this Mac."
    static let helpLine = "Ask whoever set it up for the address and key."
    static let moreAgents = "I have more than one agent"
    static let moreAgentsCaption = "One agent per line: its name, an equals sign, then its own key."
    static let moreAgentsExample = "research=paste-the-key-here"
    static let test = "Test"
    static let testing = "Testing…"
    static let moveConfirm = "Your agents will move to the new address."

    // S4 Choose your agents
    static let chooseTitle = "Choose your agents"
    static let alreadyAdded = "Already added"
    static let addLater = "More agents? Add them later: Settings → Advanced → Servers and keys."
    static func addButton(_ count: Int) -> String { count == 1 ? "Add 1 agent" : "Add \(count) agents" }

    // S5 Done
    static func doneTitle(_ count: Int) -> String { count == 1 ? "You're connected. 1 agent added." : "You're connected. \(count) agents added." }
    static func openAgent(_ name: String) -> String { "Open \(name)" }
    static let close = "Close"

    // Plain results of Test (SetupCheck). None of them ever contains a key.
    static let badAddress = "That does not look like an address. Try https://my-box.example.com"
    static func notEncrypted(port: Int?) -> String {
        "This address is not encrypted, so your key would not be sent. Ask for a secure address (starting with https://), or reach the box through a tunnel to this Mac and use http://localhost:\(port.map(String.init) ?? "<port>")."
    }
    static let unreachable = "Could not reach that address. Check it and your internet connection."
    static let keyRejected = "The box answered but did not accept that key."
    static func mainOnly(_ name: String) -> String { "This box only serves its main agent, so \(name) cannot be added." }
    static let noAgents = "The box answered but offered no agents to add."
    static func connected(to place: String, found count: Int) -> String {
        "Connected to \(place). Found \(count == 1 ? "1 agent" : "\(count) agents")."
    }
    static func notAdded(_ name: String) -> String { "\(name) could not be reached with its key." }
    static let badLine = "One of the extra lines is not in the form name=key."
    static let failed = "Could not finish. Nothing was changed."
    static let thisMac = "this Mac"

    /// Static strings only; the functions are checked with sample arguments by the tests.
    static var all: [String] {
        [windowTitle, back, cancel, skip, sampleLink, welcomeTitle, connectCardTitle, connectCardDetail, softwareLine,
         softwareTitle, hermesCardTitle, hermesCardDetail, openClawCardTitle, openClawCardDetail] + openClawScreen + [
         addressTitle, addressLabel, addressPlaceholder, keyLabel, keyCaption, keepKeyCaption, helpLine, moreAgents,
         moreAgentsCaption, moreAgentsExample, test, testing, moveConfirm, chooseTitle, alreadyAdded, addLater,
         addButton(1), addButton(3), doneTitle(1), doneTitle(3), openAgent("Ada"), close, badAddress, notEncrypted(port: 8642),
         notEncrypted(port: nil), unreachable, keyRejected, mainOnly("Ada"), noAgents, connected(to: thisMac, found: 2),
         notAdded("Ada"), badLine, failed, thisMac] + ManagedHosting.all
    }
    /// S3-OC's words (P25), all allowed to name OpenClaw.
    static var openClawScreen: [String] {
        [openClawTitle, openClawAddressLabel, openClawKeyPrompt, openClawKeyCaption, openClawPlainToggle, openClawMore, openClawDeviceName,
         openClawKeepKey, openClawHelpKey, openClawHelpTunnel, openClawHelpApprove, openClawPairing, testAgain, openClawFound(1), openClawFound(3),
         openClawNoAgents]
    }
    /// The only copy allowed to name the agent software: the S1 line, the S2 cards and the S3-OC screen (P25 D6).
    static var softwareNames: [String] { [softwareLine, hermesCardTitle, hermesCardDetail, openClawCardTitle, openClawCardDetail] + openClawScreen }
    /// The one phrase of OpenClaw's own vocabulary allowed, once, in `openClawKeyCaption`.
    static let openClawTermForKey = "Gateway token"
}
