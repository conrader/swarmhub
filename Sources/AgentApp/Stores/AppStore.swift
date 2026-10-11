import Combine
import Foundation

@MainActor final class AppStore: ObservableObject {
    @Published var bots: [Bot] = []; @Published var selectedBot: Bot?; @Published var isStreaming = false; @Published var statusText = ""; @Published var subAgents: [SubAgentTask] = []; @Published var approvals: [ApprovalRequest] = []; @Published var showSubAgents = true; @Published var selectedMode = 0; @Published var errorMessage: String?
    private var streamTask: Task<Void, Never>?; private let fileURL: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp", directoryHint: .isDirectory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); fileURL = directory.appending(path: "store.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([Bot].self, from: data) { bots = decoded }
        if bots.isEmpty { let bot = Bot(name: "Hermes", persona: "Be concise, capable, and transparent."); bot.messages.append(ChatMessage(role: .assistant, content: "Hi — I’m ready. The Mock backend is active, so you can try streaming, sub-agents, and approvals without a server.")); bots = [bot]; save() }; selectedBot = bots.first
    }
    func addBot(name: String, persona: String, backend: BackendKind) { let bot = Bot(name: name, persona: persona, backend: backend); bots.append(bot); selectedBot = bot; save() }
    func save() { guard let data = try? JSONEncoder().encode(bots) else { return }; try? data.write(to: fileURL, options: .atomic) }
    func send(text: String) {
        guard let bot = selectedBot, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; bot.messages.append(ChatMessage(role: .user, content: text)); let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true); bot.messages.append(assistant); objectWillChange.send(); save(); isStreaming = true; statusText = "Connecting"
        let history = bot.messages.filter { $0.id != assistant.id }.map { (role: $0.role.rawValue, content: $0.content) }; let backend = backend(for: bot)
        streamTask = Task { [weak self] in guard let self else { return }; do { let stream = try await backend.send(.init(sessionID: bot.id.uuidString, systemPrompt: bot.persona, messages: history)); for try await event in stream { guard !Task.isCancelled else { break }; switch event { case .token(let token): assistant.content += token; objectWillChange.send(); case .status(let value): statusText = value; case .subAgent(let task): if let i = subAgents.firstIndex(where: { $0.id == task.id }) { subAgents[i] = task } else { subAgents.append(task) }; case .approval(let request): approvals.append(request); case .completed: statusText = ""; case .failed(let value): errorMessage = value } } } catch { errorMessage = error.localizedDescription }; assistant.isStreaming = false; isStreaming = false; statusText = ""; save() }
    }
    func stop() { streamTask?.cancel(); streamTask = nil; isStreaming = false; statusText = ""; if let bot = selectedBot { Task { await backend(for: bot).cancel(sessionID: bot.id.uuidString) } }; save() }
    func decide(_ approval: ApprovalRequest, approved: Bool) { approvals.removeAll { $0.id == approval.id }; guard let bot = selectedBot else { return }; bot.messages.append(ChatMessage(role: .system, content: approved ? "Approved: \(approval.title)" : "Denied: \(approval.title)")); objectWillChange.send(); save(); Task { try? await backend(for: bot).resolveApproval(id: approval.id, approved: approved) } }
    func backend(for bot: Bot) -> any AgentBackend { switch bot.backend { case .mock: MockBackend(); case .hermes: HermesBackend(baseURL: URL(string: UserDefaults.standard.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL)!, apiKey: KeychainStore.get(account: "hermes")); case .openClaw: OpenClawBackend(gatewayURL: URL(string: UserDefaults.standard.string(forKey: "openClawURL") ?? "")) } }
}
