import Combine
import Foundation

enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case mock = "Mock", hermes = "Hermes Agent", openClaw = "OpenClaw"
    var id: String { rawValue }
    /// Chats live on the server (history, threads, features); P12 adds OpenClaw beside Hermes.
    var hasServerSessions: Bool { self == .hermes || self == .openClaw }
    var shortName: String { switch self { case .mock: "Mock"; case .hermes: "Hermes"; case .openClaw: "OpenClaw" } }
}

/// P12: an OpenClaw bot's Gateway, agent and session. The canonical session key goes in `Bot.hermesSessionID`
/// (documented reuse). `own` makes a session just for this app; `main` is `agent:<id>:<mainKey>`, shared with the
/// agent's channels.
struct OpenClawBinding: Codable, Equatable, Sendable {
    enum SessionMode: String, Codable, Sendable { case own, main }
    var gatewayID: String; var agentID: String; var sessionMode: SessionMode = .own
}

enum MessageRole: String, Codable { case user, assistant, system }
enum MessagePresentation: String, Codable { case text, draftEmail, options, attachment, image, links, voiceMemo, delegation, routineResult }

enum ApprovalMode: String, Codable, CaseIterable, Identifiable {
    case ask = "Ask me", rules = "Auto-approve by rules", reviewer = "Reviewer bot"
    var id: String { rawValue }
}
enum ApprovalRuleOutcome: String, Codable, CaseIterable, Identifiable {
    case allow, deny, ask
    var id: String { rawValue }
}
struct ApprovalRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID(); var name: String; var actionPattern: String; var commandPattern: String; var outcome: ApprovalRuleOutcome
    static var sensibleDefaults: [ApprovalRule] {
        [
            ApprovalRule(name: "Ask before deletes", actionPattern: "*", commandPattern: "rm *", outcome: .ask),
            ApprovalRule(name: "Ask before sends", actionPattern: "*", commandPattern: "send *", outcome: .ask),
            ApprovalRule(name: "Allow Git status", actionPattern: "command", commandPattern: "git status", outcome: .allow),
            ApprovalRule(name: "Allow Git status options", actionPattern: "command", commandPattern: "git status *", outcome: .allow),
            ApprovalRule(name: "Allow directory listing", actionPattern: "command", commandPattern: "ls *", outcome: .allow),
            ApprovalRule(name: "Allow file reads", actionPattern: "command", commandPattern: "cat *", outcome: .allow)
        ]
    }
    func matches(action: String, command: String) -> Bool {
        Self.glob(actionPattern, matches: action) && Self.glob(commandPattern, matches: command)
    }
    private static func glob(_ pattern: String, matches value: String) -> Bool {
        let p = Array(pattern.lowercased()), v = Array(value.lowercased()); var row = Array(repeating: false, count: v.count + 1); row[0] = true
        for token in p {
            var next = Array(repeating: false, count: v.count + 1)
            if token == "*" { next[0] = row[0]; if !v.isEmpty { for i in 1...v.count { next[i] = row[i] || next[i - 1] } } }
            else if !v.isEmpty { for i in 1...v.count where row[i - 1] && (token == "?" || token == v[i - 1]) { next[i] = true } }
            row = next
        }
        return row[v.count]
    }

    static func commandRequiresUserReview(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        let redactionMarkers = ["...", "***", "[redacted]", "<redacted>", "«redacted"]
        if redactionMarkers.contains(where: lowercased.contains) { return true }

        // Automatic approval is deliberately ASCII-only. Check scalars rather than
        // Characters: CRLF and Unicode prepend/combining sequences can be one grapheme.
        let safePunctuation = " ._/:=,@%+-"
        guard !command.isEmpty, command.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || safePunctuation.unicodeScalars.contains(scalar))
        }) else { return true }

        let tokens = command.lowercased().split(separator: " ").map(String.init)
        guard let executable = tokens.first?.split(separator: "/").last.map(String.init) else { return true }
        let dangerousPrograms: Set<String> = ["awk", "bash", "curl", "dd", "env", "find", "mkfs", "mv", "perl", "python", "python3", "scp", "sh", "ssh", "xargs"]
        let dangerousArguments: Set<String> = ["-c", "-d", "-delete", "-e", "-exec", "-execdir", "-f", "-t", "--data", "--data-ascii", "--data-binary", "--data-raw", "--exec", "--upload-file", "--upload-pack"]
        if dangerousPrograms.contains(executable) { return true }
        if executable == "git" {
            let safeSubcommands: Set<String> = ["branch", "diff", "log", "show", "status"]
            guard tokens.count > 1, safeSubcommands.contains(tokens[1]) else { return true }
            if tokens.contains(where: { $0 == "--output" || $0.hasPrefix("--output=") }) { return true }
        }
        if tokens.dropFirst().contains(where: { token in
            dangerousArguments.contains(token) || token.hasPrefix("--data=") || token.hasPrefix("--upload-pack=") ||
                (executable == "rg" && (token == "--pre" || token.hasPrefix("--pre=")))
        }) { return true }
        return false
    }

    static func reviewerMustEscalate(action: String, command: String) -> Bool {
        let action = action.lowercased()
        if action.contains("send") || action.contains("delete") || action.contains("destruct") { return true }
        let normalized = command.lowercased().filter { !["'", "\"", "\\"].contains($0) }
        let words = normalized.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }.map(String.init)
        guard let executable = words.first?.split(separator: "/").last.map(String.init) else { return true }
        let reviewablePrograms: Set<String> = ["cat", "git", "grep", "head", "ls", "pwd", "rg", "stat", "tail", "wc"]
        if !reviewablePrograms.contains(executable) { return true }
        let destructive: Set<String> = ["-delete", "dd", "delete", "mkfs", "mv", "remove", "rm", "rmdir", "send", "shred", "truncate", "unlink"]
        if words.contains(where: destructive.contains) { return true }
        if words.first == "curl", words.dropFirst().contains(where: { ["-d", "-t", "--data", "--data-ascii", "--data-binary", "--data-raw", "--upload-file"].contains($0) || $0.hasPrefix("--data=") }) { return true }
        if words.first == "find", words.contains(where: { ["-delete", "-exec", "-execdir"].contains($0) }) { return true }
        return normalized.contains(">") || normalized.contains("git push") || normalized.contains("git reset --hard") || normalized.contains("git clean -")
    }
}
enum ApprovalAuditOutcome: String, Codable { case requested, approved, denied, asked }
struct ApprovalAuditEntry: Identifiable, Codable {
    let id: UUID; let approvalID: UUID; let timestamp: Date; let actionKind: String
    var outcome: ApprovalAuditOutcome; var decidedBy: String; var reason: String
    init(id: UUID = UUID(), approvalID: UUID, timestamp: Date = .now, actionKind: String, outcome: ApprovalAuditOutcome, decidedBy: String, reason: String) {
        self.id = id; self.approvalID = approvalID; self.timestamp = timestamp; self.actionKind = actionKind; self.outcome = outcome; self.decidedBy = decidedBy; self.reason = reason
    }
}

enum BotAvatarName: String, Codable, CaseIterable, Identifiable {
    case faceCoral, faceSky, faceMint, faceSun, faceLilac, faceRose
    case faceOcean, faceLime, facePeach, faceBlue, facePlum, faceSand
    case robot, blob, bubble, headphones, fox, planet, coffee, octopus, pebble
    var id: String { rawValue }
    var isFlatFace: Bool { rawValue.hasPrefix("face") }
    var displayName: String {
        switch self {
        case .faceCoral: "Coral"; case .faceSky: "Sky"; case .faceMint: "Mint"; case .faceSun: "Sun"
        case .faceLilac: "Lilac"; case .faceRose: "Rose"; case .faceOcean: "Ocean"; case .faceLime: "Lime"
        case .facePeach: "Peach"; case .faceBlue: "Blue"; case .facePlum: "Plum"; case .faceSand: "Sand"
        default: rawValue.capitalized
        }
    }
}

final class ChatMessage: ObservableObject, Identifiable, Codable {
    let id: UUID; let role: MessageRole; @Published var content: String; let createdAt: Date
    @Published var isStreaming: Bool; var presentation: MessagePresentation; @Published var metadata: [String: String]
    @Published var reactions: [String]; var replyToID: UUID?; var attachments: [ChatAttachment]
    /// Group chats: the bot that wrote an assistant message (nil = the user, or a one-bot chat).
    var authorID: UUID?
    /// P16: the state of the turn whose reply this row holds (nil = written before P16); encoded only when set.
    @Published var turnState: TurnState?
    init(id: UUID = UUID(), role: MessageRole, content: String, createdAt: Date = .now, isStreaming: Bool = false, presentation: MessagePresentation = .text, metadata: [String: String] = [:], reactions: [String] = [], replyToID: UUID? = nil, attachments: [ChatAttachment] = [], authorID: UUID? = nil, turnState: TurnState? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt; self.isStreaming = isStreaming
        self.presentation = presentation; self.metadata = metadata; self.reactions = reactions; self.replyToID = replyToID; self.attachments = attachments; self.authorID = authorID
        self.turnState = turnState
    }
    enum CodingKeys: CodingKey { case id, role, content, createdAt, presentation, metadata, reactions, replyToID, attachments, authorID, turnState }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); role = try c.decode(MessageRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content); createdAt = try c.decode(Date.self, forKey: .createdAt)
        presentation = try c.decodeIfPresent(MessagePresentation.self, forKey: .presentation) ?? .text
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []
        replyToID = try c.decodeIfPresent(UUID.self, forKey: .replyToID)
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        authorID = try c.decodeIfPresent(UUID.self, forKey: .authorID)
        // An unknown value (a newer build's state) must not make the whole store undecodable.
        turnState = (try? c.decodeIfPresent(TurnState.self, forKey: .turnState)) ?? nil
        isStreaming = false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content); try c.encode(createdAt, forKey: .createdAt); try c.encode(presentation, forKey: .presentation)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(reactions, forKey: .reactions); try c.encodeIfPresent(replyToID, forKey: .replyToID)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(authorID, forKey: .authorID); try c.encodeIfPresent(turnState, forKey: .turnState)
    }
}

final class Bot: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID; @Published var name: String; @Published var title: String; @Published var botDescription: String
    @Published var persona: String; @Published var backend: BackendKind; @Published var unreadCount: Int
    @Published var avatarName: BotAvatarName
    /// P15: Grok's shape/colour words (nil = the classic `avatarName`); additive, so a rollback still opens the store.
    @Published var avatarMark: AvatarMark? = nil
    /// Transient: the mark was recovered by `AvatarMigration` at decode and is not saved yet.
    var avatarMarkMigrated = false
    @Published var isHidden: Bool; @Published var notificationsEnabled: Bool
    @Published var memorySummary: String; @Published var skills: [String]
    @Published var importedMemories: [String]; @Published var importedSkills: [ImportedTemplateSkill]
    @Published var requestedConnectorIDs: [String]; @Published var gettingStartedSkill: ImportedTemplateSkill?
    @Published var routines: [BotRoutine]
    /// Routine inbox: the last `last_run_at` seen per Hermes job id ("" = seen, never run), so a run gets one card.
    @Published var routineRunMarks: [String: String]
    @Published var hermesProfile: String?; @Published var hermesSessionID: String?; @Published var hermesModelLock: HermesModelLock?
    @Published var approvalMode: ApprovalMode; @Published var approvalRules: [ApprovalRule]; @Published var reviewerBotID: UUID?
    @Published var approvalAudit: [ApprovalAuditEntry]
    @Published var isDemo: Bool
    /// Threaded replies (Hermes forks) and the sidebar's manual "Mark as Unread" flag.
    @Published var threads: [ChatThread]; @Published var manualUnread: Bool
    /// Grok import: per-bot Hermes base URL, accent colour (hex), source id, archive size, and — for an
    /// archived read-only group conversation — its member names.
    @Published var hermesBaseURL: String?; @Published var accentColor: String?; @Published var grokSourceID: String?
    @Published var grokHistoryCount: Int; @Published var archivedMembers: [String]?
    /// The bot's web desktop (noVNC) for the Computer tab; validated by `ComputerURL`.
    @Published var computerURL: String?
    /// P13 per-bot model roles; nil while every role inherits, so untouched bots encode byte-identically.
    @Published var modelSettings: BotModelSettings? = nil
    /// P22: this Hermes bot manages the other bots on its connection; its box instructions as last seen; retired on the box.
    @Published var canManageBots = false; @Published var boxInstructions: BoxInstructions? = nil; @Published var retiredOnBox = false
    /// P12: the OpenClaw Gateway and agent (nil = unbound; old stores load without it).
    @Published var openClaw: OpenClawBinding? = nil
    var isReadOnlyArchive: Bool { archivedMembers != nil }
    let createdAt: Date; @Published var messages: [ChatMessage]
    init(name: String, title: String = "Personal agent", description: String = "", persona: String = "You are a thoughtful, capable assistant.", backend: BackendKind = .mock, avatarName: BotAvatarName? = nil, unreadCount: Int = 0, isHidden: Bool = false, notificationsEnabled: Bool = true, memorySummary: String = "", skills: [String] = [], importedMemories: [String] = [], importedSkills: [ImportedTemplateSkill] = [], requestedConnectorIDs: [String] = [], gettingStartedSkill: ImportedTemplateSkill? = nil, routines: [BotRoutine] = [], messages: [ChatMessage] = [], hermesProfile: String? = nil, hermesSessionID: String? = nil, approvalMode: ApprovalMode = .ask, approvalRules: [ApprovalRule] = ApprovalRule.sensibleDefaults, reviewerBotID: UUID? = nil, isDemo: Bool = false) {
        id = UUID(); self.name = name; self.title = title; botDescription = description; self.persona = persona; self.backend = backend
        self.avatarName = avatarName ?? .faceCoral; self.unreadCount = unreadCount; self.isHidden = isHidden; self.notificationsEnabled = notificationsEnabled
        self.memorySummary = memorySummary; self.skills = skills; self.importedMemories = importedMemories; self.importedSkills = importedSkills; self.requestedConnectorIDs = requestedConnectorIDs; self.gettingStartedSkill = gettingStartedSkill; self.routines = routines; self.hermesProfile = hermesProfile; self.hermesSessionID = hermesSessionID; self.approvalMode = approvalMode; self.approvalRules = approvalRules; self.reviewerBotID = reviewerBotID; approvalAudit = []; self.isDemo = isDemo; hermesBaseURL = nil; accentColor = nil; grokSourceID = nil; grokHistoryCount = 0; archivedMembers = nil; computerURL = nil; hermesModelLock = nil; routineRunMarks = [:]; threads = []; manualUnread = false; createdAt = .now; self.messages = messages
        // No explicit classic choice: the bot gets its derived mark (avatarName keeps the legacy default for older builds).
        avatarMark = avatarName == nil ? GrokDefaultLook.mark(for: id.uuidString.lowercased()) : nil
    }
    static func == (lhs: Bot, rhs: Bot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    enum CodingKeys: CodingKey { case id, name, title, botDescription, persona, backend, avatarName, unreadCount, isHidden, notificationsEnabled, memorySummary, skills, importedMemories, importedSkills, requestedConnectorIDs, gettingStartedSkill, routines, hermesProfile, hermesSessionID, approvalMode, approvalRules, reviewerBotID, approvalAudit, isDemo, hermesBaseURL, accentColor, grokSourceID, grokHistoryCount, archivedMembers, computerURL, hermesModelLock, routineRunMarks, threads, manualUnread, createdAt, messages, modelSettings, avatarMark, canManageBots, boxInstructions, retiredOnBox, openClaw }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(UUID.self, forKey: .id); let decodedName = try c.decode(String.self, forKey: .name); name = decodedName
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Personal agent"; botDescription = try c.decodeIfPresent(String.self, forKey: .botDescription) ?? ""
        persona = try c.decode(String.self, forKey: .persona); let decodedBackend = try c.decode(BackendKind.self, forKey: .backend); backend = decodedBackend
        let legacyAvatar: BotAvatarName = ["Atlas": .robot, "Mira": .blob, "Patch": .headphones, "Scout": .fox, "Nova": .planet][decodedName] ?? .robot
        avatarName = try c.decodeIfPresent(BotAvatarName.self, forKey: .avatarName) ?? legacyAvatar; unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false; notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        memorySummary = try c.decodeIfPresent(String.self, forKey: .memorySummary) ?? ""; skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        importedMemories = try c.decodeIfPresent([String].self, forKey: .importedMemories) ?? []
        importedSkills = try c.decodeIfPresent([ImportedTemplateSkill].self, forKey: .importedSkills) ?? []
        requestedConnectorIDs = try c.decodeIfPresent([String].self, forKey: .requestedConnectorIDs) ?? []
        gettingStartedSkill = try c.decodeIfPresent(ImportedTemplateSkill.self, forKey: .gettingStartedSkill)
        routines = try c.decodeIfPresent([BotRoutine].self, forKey: .routines) ?? []
        hermesProfile = try c.decodeIfPresent(String.self, forKey: .hermesProfile); hermesSessionID = try c.decodeIfPresent(String.self, forKey: .hermesSessionID)
        approvalMode = try c.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .ask; approvalRules = try c.decodeIfPresent([ApprovalRule].self, forKey: .approvalRules) ?? ApprovalRule.sensibleDefaults
        reviewerBotID = try c.decodeIfPresent(UUID.self, forKey: .reviewerBotID); approvalAudit = try c.decodeIfPresent([ApprovalAuditEntry].self, forKey: .approvalAudit) ?? []
        isDemo = try c.decodeIfPresent(Bool.self, forKey: .isDemo) ?? Bot.looksLikeLegacyDemo(name: decodedName, backend: decodedBackend)
        hermesBaseURL = try c.decodeIfPresent(String.self, forKey: .hermesBaseURL); accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor)
        grokSourceID = try c.decodeIfPresent(String.self, forKey: .grokSourceID); grokHistoryCount = try c.decodeIfPresent(Int.self, forKey: .grokHistoryCount) ?? 0
        archivedMembers = try c.decodeIfPresent([String].self, forKey: .archivedMembers); computerURL = try c.decodeIfPresent(String.self, forKey: .computerURL); hermesModelLock = try c.decodeIfPresent(HermesModelLock.self, forKey: .hermesModelLock)
        routineRunMarks = try c.decodeIfPresent([String: String].self, forKey: .routineRunMarks) ?? [:]
        modelSettings = (try? c.decodeIfPresent(BotModelSettings.self, forKey: .modelSettings)) ?? nil
        canManageBots = try c.decodeIfPresent(Bool.self, forKey: .canManageBots) ?? false; retiredOnBox = try c.decodeIfPresent(Bool.self, forKey: .retiredOnBox) ?? false
        boxInstructions = (try? c.decodeIfPresent(BoxInstructions.self, forKey: .boxInstructions)) ?? nil
        openClaw = (try? c.decodeIfPresent(OpenClawBinding.self, forKey: .openClaw)) ?? nil
        threads = try c.decodeIfPresent([ChatThread].self, forKey: .threads) ?? []; manualUnread = try c.decodeIfPresent(Bool.self, forKey: .manualUnread) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt); messages = try c.decode([ChatMessage].self, forKey: .messages)
        // A malformed mark must not cost the store; a missing one may be recovered from what the P6 importer wrote.
        avatarMark = (try? c.decodeIfPresent(AvatarMark.self, forKey: .avatarMark)) ?? nil
        if avatarMark == nil, let migrated = AvatarMigration.mark(avatarName: avatarName, accentColor: accentColor, grokSourceID: grokSourceID) {
            avatarMark = migrated; avatarMarkMigrated = true
        }
    }
    private static func looksLikeLegacyDemo(name: String, backend: BackendKind) -> Bool {
        backend == .mock && ["Atlas", "Mira", "Patch", "Scout", "Nova"].contains(name)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(title, forKey: .title)
        try c.encode(botDescription, forKey: .botDescription); try c.encode(persona, forKey: .persona); try c.encode(backend, forKey: .backend); try c.encode(avatarName, forKey: .avatarName)
        try c.encode(unreadCount, forKey: .unreadCount); try c.encode(createdAt, forKey: .createdAt); try c.encode(messages, forKey: .messages)
        try c.encode(isHidden, forKey: .isHidden); try c.encode(notificationsEnabled, forKey: .notificationsEnabled); try c.encode(memorySummary, forKey: .memorySummary); try c.encode(skills, forKey: .skills)
        try c.encode(importedMemories, forKey: .importedMemories); try c.encode(importedSkills, forKey: .importedSkills); try c.encode(requestedConnectorIDs, forKey: .requestedConnectorIDs); try c.encodeIfPresent(gettingStartedSkill, forKey: .gettingStartedSkill); try c.encode(routines, forKey: .routines)
        try c.encodeIfPresent(hermesProfile, forKey: .hermesProfile); try c.encodeIfPresent(hermesSessionID, forKey: .hermesSessionID); try c.encode(approvalMode, forKey: .approvalMode); try c.encode(approvalRules, forKey: .approvalRules); try c.encodeIfPresent(reviewerBotID, forKey: .reviewerBotID); try c.encode(approvalAudit, forKey: .approvalAudit); try c.encode(isDemo, forKey: .isDemo)
        try c.encodeIfPresent(hermesBaseURL, forKey: .hermesBaseURL); try c.encodeIfPresent(accentColor, forKey: .accentColor); try c.encodeIfPresent(grokSourceID, forKey: .grokSourceID)
        try c.encode(grokHistoryCount, forKey: .grokHistoryCount); try c.encodeIfPresent(archivedMembers, forKey: .archivedMembers); try c.encodeIfPresent(computerURL, forKey: .computerURL); try c.encodeIfPresent(hermesModelLock, forKey: .hermesModelLock)
        try c.encode(routineRunMarks, forKey: .routineRunMarks)
        try c.encode(threads, forKey: .threads); try c.encode(manualUnread, forKey: .manualUnread)
        if let modelSettings, !modelSettings.isEmpty { try c.encode(modelSettings, forKey: .modelSettings) }
        try c.encodeIfPresent(avatarMark, forKey: .avatarMark)
        if canManageBots { try c.encode(true, forKey: .canManageBots) }; if retiredOnBox { try c.encode(true, forKey: .retiredOnBox) }
        try c.encodeIfPresent(boxInstructions, forKey: .boxInstructions); try c.encodeIfPresent(openClaw, forKey: .openClaw)
    }
}

enum BotRoutineImportKind: String, Codable { case local, cron }
struct BotRoutine: Identifiable, Codable {
    let id: UUID; var name: String; var schedule: String; var prompt: String; var lastRun: String; var isEnabled: Bool; var importKind: BotRoutineImportKind
    init(id: UUID = UUID(), name: String, schedule: String, prompt: String = "", lastRun: String = "Never", isEnabled: Bool = true, importKind: BotRoutineImportKind = .local) { self.id = id; self.name = name; self.schedule = schedule; self.prompt = prompt; self.lastRun = lastRun; self.isEnabled = isEnabled; self.importKind = importKind }
    enum CodingKeys: CodingKey { case id, name, schedule, prompt, lastRun, isEnabled, importKind }
    /// Stores written before routines had a prompt, last-run text or import kind still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), schedule: try c.decodeIfPresent(String.self, forKey: .schedule) ?? "",
                  prompt: try c.decodeIfPresent(String.self, forKey: .prompt) ?? "", lastRun: try c.decodeIfPresent(String.self, forKey: .lastRun) ?? "Never",
                  isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false, importKind: try c.decodeIfPresent(BotRoutineImportKind.self, forKey: .importKind) ?? .local)
    }
}

enum SubAgentStatus: String, Codable { case queued, running, completed, failed }
struct SubAgentTask: Identifiable, Codable, Sendable { let id: UUID; var title: String; var detail: String; var status: SubAgentStatus }
struct ApprovalRequest: Identifiable, Codable, Sendable {
    let id: UUID; let title: String; let summary: String; let draft: String?
    var command: String? = nil
    var runID: String? = nil; var requestID: String? = nil
    var botID: UUID? = nil; var profile: String? = nil; var sessionID: String? = nil
    var actionKind: String = "command"

    var hasKnownCommand: Bool { !(command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}
struct BackendSession: Identifiable, Sendable { let id: String; let title: String }
struct BackendMessage: Sendable, Equatable {
    /// The box's integer row id (0.20.5 returns integers) and how the model ended the row (`stop`, `length`, `error`, …).
    let id: Int?; let role: String; let content: String; let createdAt: Date?; var finishReason: String? = nil
    init(id: Int? = nil, role: String, content: String, createdAt: Date? = nil, finishReason: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt; self.finishReason = finishReason
    }
}
enum StopTarget: Sendable, Equatable { case serverRun(String), disconnectedLegacy, noActiveRun }
enum StopOutcome: Sendable, Equatable { case requested, disconnectedLegacy, noActiveRun }
/// `replace` (P12): the whole reply text so far, when a backend's snapshot no longer extends what was streamed.
enum AgentEvent: Sendable { case token(String), replace(String), status(String), subAgent(SubAgentTask), approval(ApprovalRequest), completed, failed(String) }
