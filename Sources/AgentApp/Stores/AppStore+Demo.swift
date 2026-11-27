import Foundation

/// The same small input is available in the sample chat and in a new bot's composer.
enum ReleaseNotesExample {
    static let prompt = """
    Draft three short release notes for users from these changes.
    - Added a picker for the model each bot uses.
    - Added a local import for recent Grok Bot history.
    - Fixed local setup when another server occupies the usual port.
    """

    static let sampleReply = """
    - Choose a model for each bot when you set it up.
    - Bring recent Grok Bot conversations into SwarmHub from this Mac.
    - Set up bots locally even when another server is using the default port.
    """
}

extension AppStore {
    private func sampleLaunchConversation() -> [ChatMessage] {
        [
            ChatMessage(role: .user, content: "Can you review today’s launch plan and prepare the client update?"),
            ChatMessage(role: .assistant, content: "## Launch check-in\n\nThe release is **ready**. Two items are worth calling out:\n\n- Desktop QA passed on macOS 14 and 15\n- The support playbook needs one final approval\n\n```swift\nlet rollout = Release(stage: .ready, risk: .low)\n```"),
            ChatMessage(role: .assistant, content: "Here is the client update for you to check:\n\n```draft\nTo: Maya Chen <maya@northstar.co>\nSubject: \(AppConstants.name) launch update\n\nHi Maya,\n\nThe desktop rollout is ready for review. QA is complete and the remaining support item is queued for approval.\n\nBest,\nKonrad\n```"),
            ChatMessage(role: .assistant, content: "```choices\nHow would you like me to handle the rollout?\n1. Ship today\n2. Schedule for Monday\n3. Walk me through the launch checklist\n```"),
            ChatMessage(role: .user, content: "Schedule it for Monday, please.", reactions: ["👍"], replyToID: nil)
        ]
    }

    func makeSampleTeam() -> (bots: [Bot], selected: Bot) {
        func sample(_ name: String, _ role: String, _ shape: String, _ colour: AvatarColour, _ messages: [ChatMessage]) -> Bot {
            let bot = Bot(name: name, title: role, messages: messages, isDemo: true)
            bot.avatarMark = AvatarMark(shape: shape, colour: colour.rawValue)
            return bot
        }
        let legal = sample("Legal", "Contracts & licensing", "teardrop", .cyan,
                           [.init(role: .assistant, content: "Ready to review contracts and licensing terms.")])
        let scout = sample("Scout", "Research, briefs & reviewer", "blob", .violet,
                           [.init(role: .assistant, content: "I checked the three changes for Patch’s release notes.")])
        let patch = sample("Patch", "Releases & pull requests", "pebble", .blue,
                           [.init(role: .user, content: ReleaseNotesExample.prompt), .init(role: .assistant, content: ReleaseNotesExample.sampleReply)])
        let jarvis = sample("Jarvis", "Main bot · Coordinator", "squircle", .green, sampleLaunchConversation() + [
            .init(role: .assistant, content: "The rename is complete. My tests helper is checking the CSV reader.")])
        jarvis.canManageBots = true
        return ([jarvis, patch, scout, legal], patch)
    }

    /// Stable fixtures for snapshot renders and the headless QA runner.
    func loadDemoData() {
        bots = [
            Bot(name: "Atlas", title: "Operations lead", description: "Plans launches, coordinates work, and keeps projects moving.", avatarName: .faceCoral, messages: sampleLaunchConversation()),
            Bot(name: "Mira", title: "Research partner", description: "Finds evidence and turns it into clear decisions.", avatarName: .faceSky, unreadCount: 2, messages: [ChatMessage(role: .assistant, content: "I finished the competitor landscape and highlighted the two strongest openings.")]),
            Bot(name: "Patch", title: "Engineering agent", description: "Builds, reviews, and tests product changes.", avatarName: .faceMint, messages: [ChatMessage(role: .user, content: ReleaseNotesExample.prompt), ChatMessage(role: .assistant, content: ReleaseNotesExample.sampleReply)]),
            Bot(name: "Scout", title: "Travel and logistics", description: "Handles itineraries, bookings, and practical details.", avatarName: .faceSun, unreadCount: 1, messages: [ChatMessage(role: .assistant, content: "I found three quiet hotels near the venue with flexible cancellation.")]),
            Bot(name: "Nova", title: "Creative studio", description: "Develops concepts, copy, and visual directions.", avatarName: .faceLilac, messages: [ChatMessage(role: .assistant, content: "The new onboarding directions are ready whenever you want to review them.")])
        ]
        bots.forEach { $0.isDemo = true }
    }
}
