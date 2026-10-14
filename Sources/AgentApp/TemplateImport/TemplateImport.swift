import Foundation

enum TemplateImportStatus: String, Codable, CaseIterable {
    case mapped, converted, skipped, unsupported
}

struct TemplateImportReportItem: Identifiable, Codable, Equatable {
    let id: UUID
    let category: String
    let name: String
    let status: TemplateImportStatus
    let reason: String

    init(category: String, name: String, status: TemplateImportStatus, reason: String) {
        id = UUID(); self.category = category; self.name = name; self.status = status; self.reason = reason
    }
}

struct ImportedTemplateSkill: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var markdown: String
    var isGettingStarted: Bool
    var isEnabled: Bool

    init(name: String, markdown: String, isGettingStarted: Bool = false, isEnabled: Bool = false) {
        id = UUID(); self.name = name; self.markdown = markdown
        self.isGettingStarted = isGettingStarted; self.isEnabled = isEnabled
    }
}

struct ImportedTemplateManifest: Equatable {
    struct Memory: Equatable { var name: String; var value: String }
    struct Routine: Equatable { var name: String; var prompt: String; var schedule: String?; var trigger: String? }

    var name = "Imported agent"
    var slug: String?
    var title = "Imported template"
    var description = ""
    var avatar: String?
    var instructions = "You are a thoughtful, capable assistant."
    var memories: [Memory] = []
    var skills: [ImportedTemplateSkill] = []
    var routines: [Routine] = []
    var connectorIDs: [String] = []
    var gettingStartedSkill: ImportedTemplateSkill?
    var rejectedSecretCount = 0
    var nameWasProvided = false
    var titleWasProvided = false
    var descriptionWasProvided = false
    var instructionsWereProvided = false
}

struct TemplateImportPlan {
    let manifest: ImportedTemplateManifest
    let report: [TemplateImportReportItem]
    let avatarName: BotAvatarName
    let mappedConnectorIDs: [String]
    let routines: [BotRoutine]
    var hermesProfile: String? = nil
}

enum TemplateImportError: LocalizedError {
    case invalidJSON
    case invalidLink
    case notExportJSON
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "This file is not a valid template export JSON."
        case .invalidLink: "Enter an http or https share link."
        case .notExportJSON: "The share link did not resolve directly to export JSON. Export the template as a JSON file and import that file instead."
        case .tooLarge: "The template export is larger than the 5 MB import limit."
        }
    }
}

enum GrokTemplateParser {
    static let maximumBytes = 5 * 1024 * 1024
    private static let secretKeys = [
        "token", "secret", "password", "passwd", "credential", "privatekey", "apikey", "authorization", "cookie",
        "auth", "bearer", "jwt", "passphrase", "pwd", "accesskey", "awsaccesskeyid", "sessionkey", "webhookurl", "dsn", "connectionstring"
    ]
    /// Internal so the Grok importer can share it (`GrokRedactor` precompiles it once); the order is `GrokRedactor.categories`.
    static let secretValuePatterns = [
        #"(?s)-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----.*?(?:-----END \1-----[^\r\n]*(?:\r?\n|\z)|\z)"#,
        #"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
        #"\b(sk|xox[baprs]|gh[pousr])[-_][A-Za-z0-9_-]{12,}\b"#,
        #"github_pat_[A-Za-z0-9_-]+"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
        #"xapp-[A-Za-z0-9_-]+"#,
        #"https?://hooks\.slack\.com/services/[^\s]+"#,
        #"://[^/\s:@]+:[^/\s@]+@"#,
        #"(?i)(?<![A-Za-z0-9])(api[_ -]?key|token|secret|password|credential|auth[_-]?token|access[_-]?token|client[_-]?secret|authorization)\s*[:=]\s*\S+"#
    ]

    static func parse(_ data: Data) throws -> ImportedTemplateManifest {
        guard data.count <= maximumBytes else { throw TemplateImportError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data), let raw = root as? [String: Any] else { throw TemplateImportError.invalidJSON }
        var rejected = 0
        guard let clean = sanitize(raw, rejected: &rejected) as? [String: Any] else { throw TemplateImportError.invalidJSON }
        let object = dictionary(clean, keys: ["template", "bot", "agent", "grokBot", "grok_bot"]) ?? clean
        var result = ImportedTemplateManifest()
        let suppliedName = string(object, keys: ["name", "botName", "bot_name"])
        let suppliedTitle = string(object, keys: ["title", "subtitle"])
        let suppliedDescription = string(object, keys: ["description", "shortDescription", "short_description"])
        let suppliedInstructions = string(object, keys: ["instructions", "persona", "systemPrompt", "system_prompt", "soul"])
        result.nameWasProvided = suppliedName != nil || suppliedTitle != nil
        result.titleWasProvided = suppliedTitle != nil
        result.descriptionWasProvided = suppliedDescription != nil
        result.instructionsWereProvided = suppliedInstructions != nil
        result.name = suppliedName ?? suppliedTitle ?? result.name
        result.title = suppliedTitle ?? "Imported template"
        result.description = suppliedDescription ?? ""
        result.slug = string(object, keys: ["slug", "botSlug", "bot_slug", "handle"])
        result.avatar = string(object, keys: ["avatar", "avatarUrl", "avatar_url", "icon"])
        result.instructions = suppliedInstructions ?? result.instructions
        result.memories = parseMemories(value(object, keys: ["selectedMemories", "selected_memories", "memories", "memory"]))
        result.skills = parseSkills(value(object, keys: ["skills", "capabilities"]))
        result.routines = parseRoutines(value(object, keys: ["routines", "automations"]))
        result.connectorIDs = parseIDs(value(object, keys: ["pluginIds", "plugin_ids", "plugins", "connectorIds", "connector_ids", "connectors"]))
        if let rawGettingStarted = value(object, keys: ["gettingStartedSkill", "getting_started_skill", "gettingStarted", "getting_started"]),
           let skill = parseSkill(rawGettingStarted, fallbackName: "Getting started") {
            result.gettingStartedSkill = ImportedTemplateSkill(name: skill.name, markdown: skill.markdown, isGettingStarted: true, isEnabled: false)
        }
        result.rejectedSecretCount = rejected
        return result
    }

    private static func sanitize(_ value: Any, key: String? = nil, rejected: inout Int) -> Any? {
        if let key, secretKeys.contains(where: { normalize(key).contains(normalize($0)) }) { rejected += 1; return nil }
        if let text = value as? String {
            let result = redactSecrets(text)
            rejected += result.count
            return result.text
        }
        if let object = value as? [String: Any] {
            var clean: [String: Any] = [:]
            for (childKey, childValue) in object { if let sanitized = sanitize(childValue, key: childKey, rejected: &rejected) { clean[childKey] = sanitized } }
            return clean
        }
        if let array = value as? [Any] { return array.compactMap { sanitize($0, rejected: &rejected) } }
        return value
    }

    /// The shared secret filter: Basic credentials and every `secretValuePatterns` hit are replaced.
    static func redactSecrets(_ text: String, replacement: String = "[removed]") -> (text: String, count: Int) {
        var redacted = text; var count = 0
        let basicPattern = #"(?i)\bBasic\s+([A-Za-z0-9+/]{4,}={0,2})(?![A-Za-z0-9+/=])"#
        if let expression = try? NSRegularExpression(pattern: basicPattern) {
            for result in expression.matches(in: redacted, range: NSRange(redacted.startIndex..., in: redacted)).reversed() {
                guard let match = Range(result.range, in: redacted),
                      let credentialRange = Range(result.range(at: 1), in: redacted),
                      let decoded = Data(base64Encoded: String(redacted[credentialRange])),
                      String(data: decoded, encoding: .utf8)?.contains(":") == true else { continue }
                redacted.replaceSubrange(match, with: replacement)
                count += 1
            }
        }
        for pattern in secretValuePatterns {
            var searchStart = redacted.startIndex
            while let range = redacted.range(of: pattern, options: .regularExpression, range: searchStart..<redacted.endIndex) {
                let offset = redacted.distance(from: redacted.startIndex, to: range.lowerBound) + replacement.count
                redacted.replaceSubrange(range, with: replacement)
                count += 1
                searchStart = redacted.index(redacted.startIndex, offsetBy: offset, limitedBy: redacted.endIndex) ?? redacted.endIndex
            }
        }
        return (redacted, count)
    }

    private static func parseMemories(_ raw: Any?) -> [ImportedTemplateManifest.Memory] {
        array(raw).enumerated().compactMap { index, item in
            if let text = item as? String { return .init(name: "Memory \(index + 1)", value: text) }
            guard let item = item as? [String: Any], let text = string(item, keys: ["value", "content", "text", "fact"]) else { return nil }
            return .init(name: string(item, keys: ["name", "title", "type"]) ?? "Memory \(index + 1)", value: text)
        }
    }

    private static func parseSkills(_ raw: Any?) -> [ImportedTemplateSkill] {
        array(raw).enumerated().compactMap { parseSkill($0.element, fallbackName: "Skill \($0.offset + 1)") }
    }

    private static func parseSkill(_ raw: Any, fallbackName: String) -> ImportedTemplateSkill? {
        if let markdown = raw as? String { return ImportedTemplateSkill(name: fallbackName, markdown: markdown) }
        guard let item = raw as? [String: Any], let markdown = string(item, keys: ["markdown", "instructions", "content", "prompt"]) else { return nil }
        return ImportedTemplateSkill(name: string(item, keys: ["name", "title"]) ?? fallbackName, markdown: markdown)
    }

    private static func parseRoutines(_ raw: Any?) -> [ImportedTemplateManifest.Routine] {
        array(raw).enumerated().compactMap { index, raw in
            guard let item = raw as? [String: Any] else { return nil }
            let prompt = string(item, keys: ["prompt", "instructions", "content"]) ?? ""
            let schedule = string(item, keys: ["schedule", "cron", "cronExpression", "cron_expression"])
            let trigger = string(item, keys: ["trigger", "event", "eventTrigger", "event_trigger"])
            guard !prompt.isEmpty || schedule != nil || trigger != nil else { return nil }
            return .init(name: string(item, keys: ["name", "title"]) ?? "Routine \(index + 1)", prompt: prompt, schedule: schedule, trigger: trigger)
        }
    }

    private static func parseIDs(_ raw: Any?) -> [String] {
        array(raw).compactMap { item in
            if let text = item as? String { return text }
            if let item = item as? [String: Any] { return string(item, keys: ["id", "pluginId", "plugin_id", "connectorId", "connector_id"]) }
            return nil
        }
    }

    private static func array(_ raw: Any?) -> [Any] { raw as? [Any] ?? (raw.map { [$0] } ?? []) }
    private static func normalize(_ value: String) -> String { value.lowercased().filter(\.isLetter) }
    private static func value(_ object: [String: Any], keys: [String]) -> Any? {
        for key in keys { if let pair = object.first(where: { normalize($0.key) == normalize(key) }) { return pair.value } }
        return nil
    }
    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        guard let value = value(object, keys: keys) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func dictionary(_ object: [String: Any], keys: [String]) -> [String: Any]? { value(object, keys: keys) as? [String: Any] }
}

enum TemplateImportMapper {
    // IDs are inert requests. A connector still requires a separate owner authorization.
    static let connectorMap = ["google-drive": "google-drive", "googledrive": "google-drive", "slack": "slack", "notion": "notion", "dropbox": "dropbox"]

    static func makePlan(from manifest: ImportedTemplateManifest, hermesConfigured: Bool = true, hermesProfile: String? = nil) -> TemplateImportPlan {
        func metadataRow(_ name: String, provided: Bool, mappedReason: String) -> TemplateImportReportItem {
            .init(category: name == "Persona" ? "Instructions" : "Bot", name: name, status: provided ? .mapped : .skipped,
                  reason: provided ? mappedReason : "Not provided; default used.")
        }
        var report: [TemplateImportReportItem] = [
            metadataRow("Name", provided: manifest.nameWasProvided, mappedReason: "Used as \(AppConstants.name) bot metadata."),
            metadataRow("Title", provided: manifest.titleWasProvided, mappedReason: "Used as \(AppConstants.name) bot metadata."),
            metadataRow("Description", provided: manifest.descriptionWasProvided, mappedReason: "Used as \(AppConstants.name) bot metadata."),
            metadataRow("Persona", provided: manifest.instructionsWereProvided, mappedReason: "Used as the Hermes session system prompt.")
        ]
        let boundProfile = hermesConfigured ? hermesProfile : nil
        if let boundProfile {
            report.append(.init(category: "Runtime", name: "Hermes profile", status: .mapped, reason: "Bound to Hermes profile \(boundProfile) (a key for it is in the Keychain); its tools, memory and skills apply."))
        } else if hermesConfigured {
            report.append(.init(category: "Runtime", name: "Hermes profile", status: .converted, reason: "Runs on your default Hermes profile; its tools, memory and skills apply."))
        }
        var avatar: BotAvatarName = .faceCoral
        if let sourceAvatar = manifest.avatar {
            if let exact = BotAvatarName(rawValue: sourceAvatar) { avatar = exact; report.append(.init(category: "Bot", name: "Avatar", status: .mapped, reason: "Matched a \(AppConstants.name) avatar.")) }
            else { report.append(.init(category: "Bot", name: "Avatar", status: .converted, reason: "External avatar data is not copied; the default \(AppConstants.name) avatar will be used.")) }
        }
        for memory in manifest.memories { report.append(.init(category: "Memory", name: memory.name, status: .converted, reason: "Saved with the bot in \(AppConstants.name); not yet given to the agent or Hermes memory.")) }
        for skill in manifest.skills { report.append(.init(category: "Skill", name: skill.name, status: .converted, reason: "Preserved as Markdown in the inert Hermes template configuration; runtime installation is not exposed by the connected API.")) }
        var routines: [BotRoutine] = []
        for routine in manifest.routines {
            if let schedule = routine.schedule {
                routines.append(.init(name: routine.name, schedule: schedule, prompt: routine.prompt, isEnabled: false, importKind: .cron))
                report.append(.init(category: "Routine", name: routine.name, status: .converted, reason: "Stored as a disabled routine; \"Create on server\" in the Routines tab creates it on Hermes, paused."))
            } else if routine.trigger != nil {
                report.append(.init(category: "Routine", name: routine.name, status: .unsupported, reason: "Event triggers are not carried over."))
            } else {
                report.append(.init(category: "Routine", name: routine.name, status: .skipped, reason: "No schedule or supported trigger was provided."))
            }
        }
        var mappedConnectors: [String] = []
        for connector in manifest.connectorIDs {
            if let mapped = connectorMap[connector.lowercased()] {
                mappedConnectors.append(mapped)
                report.append(.init(category: "Connector", name: connector, status: .converted, reason: "Mapped to \(mapped); access is not granted and requires separate authorization."))
            } else { report.append(.init(category: "Connector", name: connector, status: .unsupported, reason: "Unknown connector ID; it is not carried over.")) }
        }
        if let skill = manifest.gettingStartedSkill {
            report.append(.init(category: "Getting started", name: skill.name, status: .converted, reason: "Preserved but disabled until the owner reviews and activates it for the first conversation."))
        }
        if manifest.rejectedSecretCount > 0 {
            let noun = manifest.rejectedSecretCount == 1 ? "field or value was" : "fields or values were"
            report.append(.init(category: "Security", name: "Sensitive values", status: .skipped, reason: "\(manifest.rejectedSecretCount) sensitive \(noun) removed before preview and storage."))
        }
        return TemplateImportPlan(manifest: manifest, report: report, avatarName: avatar, mappedConnectorIDs: Array(Set(mappedConnectors)).sorted(), routines: routines, hermesProfile: boundProfile)
    }
}

enum TemplateImportLoader {
    static func load(link: String, session: URLSession = TestRunGuard.sharedSession) async throws -> Data {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw TemplateImportError.invalidLink }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard data.count <= GrokTemplateParser.maximumBytes else { throw TemplateImportError.tooLarge }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().contains("json") == true,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw TemplateImportError.notExportJSON }
        return data
    }
}
