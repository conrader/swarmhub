import Combine
import Foundation
import AppKit
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var bots: [Bot] = []; @Published var selectedBot: Bot?; @Published var isStreaming = false
    @Published var approvals: [ApprovalRequest] = []
    @Published var showInfo = true; @Published var showingNewBot = false; @Published var showingCommandPalette = false
    @Published var showingHiddenBots = false; @Published var replyTo: ChatMessage?
    @Published var routines: [UUID: [BotRoutine]] = [:]
    @Published var editingBot: Bot?; @Published var errorMessage: String?
    private var streamTask: Task<Void, Never>?; private let fileURL: URL
    private var streamingBotID: UUID?; private var streamingAssistant: ChatMessage?
    private var persistenceEnabled = true

    init(demoMode: Bool = false) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); fileURL = directory.appending(path: "store.json")
        if demoMode {
            persistenceEnabled = false
            loadDemoData(includeActivity: true)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                bots = try JSONDecoder().decode([Bot].self, from: Data(contentsOf: fileURL))
            } catch {
                persistenceEnabled = false
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingLastPathComponent().appending(path: "store.json.corrupt-\(stamp)")
                do { try FileManager.default.moveItem(at: fileURL, to: backup) }
                catch { errorMessage = "Could not read or back up store.json: \(error.localizedDescription)" }
                if errorMessage == nil { errorMessage = "The saved store could not be decoded. It was moved to \(backup.lastPathComponent); saving is disabled for this launch." }
            }
        } else {
            loadDemoData(persist: true)
        }
        selectedBot = bots.first
    }

    func loadDemoData(persist: Bool = false, includeActivity: Bool = false) {
        let conversation = [
            ChatMessage(role: .user, content: "Can you review today’s launch plan and prepare the client update?"),
            ChatMessage(role: .assistant, content: "## Launch check-in\n\nThe release is **ready**. Two items are worth calling out:\n\n- Desktop QA passed on macOS 14 and 15\n- The support playbook needs one final approval\n\n```swift\nlet rollout = Release(stage: .ready, risk: .low)\n```"),
            ChatMessage(role: .assistant, content: "Draft ready", presentation: .draftEmail, metadata: ["to": "Maya Chen <maya@northstar.co>", "subject": "AgentApp launch update", "body": "Hi Maya,\n\nThe desktop rollout is ready for review. QA is complete and the remaining support item is queued for approval.\n\nBest,\nKonrad"]),
            ChatMessage(role: .assistant, content: "How would you like me to handle the rollout?", presentation: .options, metadata: ["options": "Ship today|Schedule for Monday|Open launch checklist"]),
            ChatMessage(role: .user, content: "Schedule it for Monday, please.", reactions: ["👍"], replyToID: nil),
            ChatMessage(role: .assistant, content: "Voice note", presentation: .voiceMemo, metadata: ["duration": "0:18"]),
            ChatMessage(role: .assistant, content: "Launch assets", presentation: .attachment, metadata: ["name": "launch-checklist.pdf", "size": "1.8 MB"]),
            ChatMessage(role: .assistant, content: "Useful links", presentation: .links, metadata: ["links": "Release board|QA report|Support plan"])
        ]
        bots = [
            Bot(name: "Atlas", title: "Operations lead", description: "Plans launches, coordinates work, and keeps projects moving.", avatarName: .faceCoral, memorySummary: "Knows the launch plan, client preferences, and weekly operating rhythm.", skills: ["Planning", "Email", "Project tracking"], messages: conversation),
            Bot(name: "Mira", title: "Research partner", description: "Finds evidence and turns it into clear decisions.", avatarName: .faceSky, unreadCount: 2, skills: ["Web research", "Synthesis"], messages: [ChatMessage(role: .assistant, content: "I finished the competitor landscape and highlighted the two strongest openings.")]),
            Bot(name: "Patch", title: "Engineering agent", description: "Builds, reviews, and tests product changes.", avatarName: .faceMint, skills: ["Code", "Testing"], messages: [ChatMessage(role: .assistant, content: "The CI run is green. I left a summary in the release branch.")]),
            Bot(name: "Scout", title: "Travel and logistics", description: "Handles itineraries, bookings, and practical details.", avatarName: .faceSun, unreadCount: 1, messages: [ChatMessage(role: .assistant, content: "I found three quiet hotels near the venue with flexible cancellation.")]),
            Bot(name: "Nova", title: "Creative studio", description: "Develops concepts, copy, and visual directions.", avatarName: .faceLilac, messages: [ChatMessage(role: .assistant, content: "The new onboarding directions are ready whenever you want to review them.")])
        ]
        if includeActivity { loadDemoActivity() }
        if persist { save() }
    }
    private func loadDemoActivity() {
        approvals = [.init(id: UUID(), title: "Publish release notes", summary: "Atlas wants to publish the reviewed release notes to the client workspace.", draft: nil)]
        if let id = bots.first?.id { routines[id] = [.init(name: "Morning brief", schedule: "Weekdays at 8:30", lastRun: "Today, 8:31"), .init(name: "Launch monitor", schedule: "When CI completes", lastRun: "Yesterday", isEnabled: false)] }
    }
    func addBot(name: String, persona: String, backend: BackendKind, avatarName: BotAvatarName) { let bot = Bot(name: name, persona: persona, backend: backend, avatarName: avatarName); bots.insert(bot, at: 0); selectedBot = bot; save() }
    func delete(_ bot: Bot) { bots.removeAll { $0.id == bot.id }; if selectedBot == bot { selectedBot = bots.first }; save() }
    func save() { guard persistenceEnabled, let data = try? JSONEncoder().encode(bots) else { return }; try? data.write(to: fileURL, options: .atomic) }
    func send(text: String) {
        guard !isStreaming, streamTask == nil, let bot = selectedBot, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) }
        catch { errorMessage = error.localizedDescription; return }
        bot.messages.append(ChatMessage(role: .user, content: text, replyToID: replyTo?.id)); replyTo = nil; let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true); bot.messages.append(assistant)
        objectWillChange.send(); save(); isStreaming = true; streamingBotID = bot.id; streamingAssistant = assistant
        let history = bot.messages.filter { $0.id != assistant.id }.map { (role: $0.role.rawValue, content: $0.content) }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                let stream = try await activeBackend.send(.init(sessionID: bot.id.uuidString, systemPrompt: bot.persona, messages: history))
                for try await event in stream { guard !Task.isCancelled else { break }; switch event {
                case .token(let token): assistant.content += token; objectWillChange.send()
                case .status, .subAgent: break
                case .approval(let request): approvals.append(request)
                case .completed: break
                case .failed(let value): errorMessage = value; failed = true
                } }
            } catch is CancellationError {
                // User-initiated cancellation is not an error and must not notify.
            } catch { errorMessage = error.localizedDescription; failed = true }
            let cancelled = Task.isCancelled
            assistant.isStreaming = false; isStreaming = false; streamTask = nil; streamingBotID = nil; streamingAssistant = nil; save()
            if !cancelled && !failed && !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notifyIfNeeded(bot: bot, message: assistant.content) }
        }
    }
    private func notifyIfNeeded(bot: Bot, message: String) {
        guard Bundle.main.bundleIdentifier != nil, bot.notificationsEnabled, UserDefaults.standard.bool(forKey: "notifications"), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = bot.name; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func stop() {
        guard isStreaming else { return }
        let bot = streamingBotID.flatMap { id in bots.first { $0.id == id } }
        streamTask?.cancel(); streamingAssistant?.isStreaming = false
        if let bot, let activeBackend = try? backend(for: bot) { Task { await activeBackend.cancel(sessionID: bot.id.uuidString) } }
        save()
    }
    func decide(_ approval: ApprovalRequest, approved: Bool) {
        approvals.removeAll { $0.id == approval.id }; guard let bot = selectedBot else { return }
        bot.messages.append(ChatMessage(role: .system, content: approved ? "Approved: \(approval.title)" : "Declined: \(approval.title)")); objectWillChange.send(); save()
        if let approvalBackend = try? backend(for: bot) { Task { try? await approvalBackend.resolveApproval(id: approval.id, approved: approved) } }
    }
    func backend(for bot: Bot) throws -> any AgentBackend { switch bot.backend {
    case .mock: return MockBackend()
    case .hermes:
        guard let baseURL = HermesBackend.validatedBaseURL(UserDefaults.standard.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { throw BackendError.invalidURL }
        return HermesBackend(baseURL: baseURL, apiKey: KeychainStore.get(account: "hermes"))
    case .openClaw: return OpenClawBackend(gatewayURL: URL(string: UserDefaults.standard.string(forKey: "openClawURL") ?? ""))
    } }
}
