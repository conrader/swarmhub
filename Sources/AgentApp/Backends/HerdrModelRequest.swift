import Foundation

/// A server's main bot asks the app to change which agent program and model bots run on: a ```swarmhub fence in its
/// reply holding `{"op":"set_model","decision":…,"bots":"all" | ["Name", …],"runtime":…,"model":…}`. Which program
/// and model a bot runs on is the app's setting, so the bot changes nothing on the server: the app reads the request
/// from the finished reply, matches it against what the server offers, and changes the setting of each bot
/// (`AppStore+HerdrModels.swift`). The fence is the family of `HerdrBotRequest`.
/// Foundation only, so the parser and the matching also build on Linux beside `HerdrClient`.
struct HerdrModelRequest: Equatable, Sendable {
    /// The bots by name; empty with `all`.
    var bots: [String]
    /// Every bot on the main bot's server.
    var all: Bool
    /// An agent program by its name, or a template name; nil keeps each bot's program.
    var runtime: String?
    /// A model ID, or the model's name as the person said it ("sol 6.2"); nil means the program's recommended model.
    var model: String?
    /// The main bot wrote `"decision":"decided"`: the person asked for exactly this. False asks the person.
    var decided = false

    static let op = "set_model", perReply = 4, botLimit = 80, modelLimit = 160
    /// Only the note that explains the block (and a block that follows it) contains it: a running agent reads it once.
    static let marker = "\"op\":\"\(op)\""
    static let allWord = "all", recommendedWords = ["recommended", "default"]
    /// On the message that tells the main bot a request could not be applied, so its corrected answer is not
    /// answered with a second such message (`AppStore.settleHerdrModels`).
    static let outcomeKey = "herdrModelOutcome"

    init(bots: [String] = [], all: Bool = false, runtime: String? = nil, model: String? = nil, decided: Bool = false) {
        self.bots = bots; self.all = all; self.runtime = runtime; self.model = model; self.decided = decided
    }

    /// Every model request in a reply, in order. A fence that is not valid JSON, or still being written, yields nothing.
    static func requests(in reply: String) -> [HerdrModelRequest] {
        Array(HerdrBotRequest.objects(in: reply).compactMap { HerdrModelRequest($0) }.prefix(perReply))
    }

    /// nil unless the object is a `set_model` that names bots (or all of them) and a program, a model, or both.
    init?(_ object: [String: Any]) {
        guard object["op"] as? String == Self.op else { return nil }
        func word(_ value: Any?, limit: Int = 80) -> String? {
            (value as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0.count > limit ? nil : $0 }
        }
        let named = object["bots"] ?? object["bot"]
        if let one = named as? String {
            if one.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.allWord { all = true; bots = [] }
            else if let name = HerdrBotRequest.name(one) { all = false; bots = [name] }
            else { return nil }
        } else if let several = named as? [Any] {
            var names: [String] = []
            for name in several.compactMap({ HerdrBotRequest.name($0) }) where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
            guard !names.isEmpty, names.count <= Self.botLimit else { return nil }
            all = false; bots = names
        } else { return nil }
        runtime = word(object["runtime"] ?? object["program"])
        let wanted = word(object["model"], limit: Self.modelLimit)
        // "recommended" is a choice of its own, so a request may name it alone.
        let recommended = wanted.map { Self.recommendedWords.contains($0.lowercased()) } ?? false
        model = recommended ? nil : wanted
        guard runtime != nil || wanted != nil else { return nil }
        decided = word(object["decision"])?.lowercased() == HerdrBotRequest.decidedWord
    }

    /// Whose setting is asked to change, in a few words: "All bots" or the names.
    var who: String {
        if all { return "All bots" }
        return bots.count > 3 ? bots.prefix(3).joined(separator: ", ") + " and \(bots.count - 3) more" : bots.joined(separator: ", ")
    }

    /// What it is asked to change to, as the request words it.
    var what: String { [runtime, model ?? "Recommended model"].compactMap { $0 }.joined(separator: " · ") }

    // MARK: Matching a model by what the person called it

    enum Match: Equatable, Sendable { case one(HerdrClient.Template.Model), several([HerdrClient.Template.Model]), none }

    /// The offered model `wanted` means: its ID or its name exactly, else the one whose ID and name together hold
    /// every word of it ("sol 6.2" finds "gpt-6.2-sol"). When several hold every word, the one with the plainest ID
    /// is meant ("gpt-6.2-sol", not "gpt-6.2-sol-mini"), unless two are equally plain.
    static func match(_ wanted: String, in offered: [HerdrClient.Template.Model]) -> Match {
        let text = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = Set(tokens(text))
        guard !words.isEmpty else { return .none }
        if let exact = offered.first(where: { $0.id.lowercased() == text }) ?? offered.first(where: { $0.label?.lowercased() == text }) { return .one(exact) }
        let hits = offered.filter { model in words.isSubset(of: vocabulary(model.id + " " + (model.label ?? ""))) }
        guard hits.count > 1 else { return hits.first.map(Match.one) ?? .none }
        let sizes = hits.map { tokens($0.id).count }, least = sizes.min() ?? 0
        let plainest = zip(hits, sizes).filter { $0.1 == least }.map { $0.0 }
        return plainest.count == 1 ? .one(plainest[0]) : .several(hits)
    }

    /// Lowercased words; letters and digits make a word, and a dot stays inside one ("6.2").
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
    }

    /// The words a model can be called by: its tokens, the parts of a dotted one ("6.2" also as "6" and "2"), and
    /// two neighbouring numbers as one version ("5", "5" also as "5.5").
    static func vocabulary(_ text: String) -> Set<String> {
        let words = tokens(text)
        var all = Set(words)
        for word in words where word.contains(".") { all.formUnion(word.split(separator: ".").map(String.init)) }
        for (first, second) in zip(words, words.dropFirst()) where first.allSatisfy(\.isNumber) && second.allSatisfy(\.isNumber) { all.insert(first + "." + second) }
        return all
    }

    // MARK: What the bots are told

    /// What a server's main bot is told with its other notes, and once when it is already running: the block in a few
    /// words, because the notes share a small room (`HerdrClient.notesBytes`). `how` says the rest when it is needed.
    static let brief = """
        To change which agent program or model bots run on, when the person asks for it, end your reply with a block like:

        ```swarmhub
        {"op":"\(op)","decision":"\(HerdrBotRequest.decidedWord)","bots":"\(allWord)","runtime":"Codex","model":"sol 6.2"}
        ```

        "bots" is "\(allWord)" or a list of names; "model" is the model as the person called it. SwarmHub matches it against \
        the server's models, applies it, and tells you when it cannot. Never change a model any other way.
        """

    /// What the main bot reads in front of a message that asks for a model change (`ManagementIntent.changesModel`).
    static let how = """
        The person may be asking you to change which agent program or model bots run on. That is a setting of SwarmHub, \
        the app they are chatting from, and you have it changed by ending your reply with a fenced block like this:

        ```swarmhub
        {"op":"\(op)","decision":"\(HerdrBotRequest.decidedWord)","bots":"\(allWord)","runtime":"Codex","model":"sol 6.2"}
        ```

        "bots" is "\(allWord)" (every bot on your server, you included) or a list of bot names. "runtime" names the agent \
        program ("Claude", "Codex", "OpenCode" or "Gemini"); leave it out to keep each bot's program. "model" is a model ID, \
        or the model's name as the person said it: SwarmHub matches it against the models your server offers. \
        "recommended" is the program's recommended model. Give "runtime", "model" or both. \
        "decision" is "\(HerdrBotRequest.decidedWord)" when the person asked for exactly this change in the message you are \
        answering: SwarmHub applies it and shows them Undo. With "\(HerdrBotRequest.askWord)", or when they have chosen to confirm \
        what you do, they get Apply and Not now first. If SwarmHub cannot match the program or the model, it tells you which \
        ones the server has. A bot whose agent is running keeps its current model until that agent is started fresh, \
        which the person does from the card SwarmHub shows them. So say that you asked SwarmHub to change the setting \
        and that they will see it above the message box, not that every bot has switched. The app hides the block. \
        Do not edit files or restart agents yourself to change a model.
        """

    /// What every other bot is reminded of when its person asks it for a model change.
    static func elsewhere(main: String?) -> String {
        let who = main.map { "The main bot, \($0), can have SwarmHub do it" } ?? "This server has no main bot that could have SwarmHub do it"
        return "Only if the person is asking you to change which agent program or model a bot runs on (yours or another bot's): you cannot. \(who), and the person can do it themselves in SwarmHub under Settings → Servers (“All bots on this server”) or in one bot's Details; say that in a sentence. If they are asking for anything else, ignore this note."
    }

    /// What the main bot is told when its request could not be applied.
    static func notApplied(_ refusal: HerdrModelRefusal) -> String {
        "\(HerdrBotRelay.appLead)\nThe model change was not applied. \(refusal.text)\nThe person did not write this. End your reply with a corrected \(op) block, or ask the person what they meant."
    }
}

/// What a request comes to on one server: each bot's new program and model, and what it ran on before.
struct HerdrModelPlan: Equatable, Sendable {
    /// One bot's change. `template` is the program's template by name; the `before…` values are the bot's settings
    /// as they were stored (an empty template follows the shared choice), so Undo puts back exactly those.
    struct Change: Codable, Equatable, Sendable {
        var bot: UUID; var name: String; var template: String; var model: String; var beforeTemplate: String; var beforeModel: String
    }
    /// A bot as the plan needs it: its stored choices and the template those resolve to on the server now.
    struct Target: Equatable, Sendable {
        var id: UUID; var name: String; var ownTemplate: String; var template: String?; var model: String
    }

    var changes: [Change]
    /// The named bots that already run as asked.
    var unchanged: Int
    /// What they change to, for the person: "Codex · GPT-6.2 Sol".
    var label: String

    static let recommendedLabel = "Recommended model"

    /// The plan for `request`, or why there is none. `bots` are the server's bots, `templates` its usable programs and
    /// `offered` the models each lists (by template name). Nothing is changed unless every named bot can be.
    static func make(_ request: HerdrModelRequest, bots: [Target], templates: [HerdrClient.Template], offered: [String: [HerdrClient.Template.Model]]) -> Result<HerdrModelPlan, HerdrModelRefusal> {
        var targets = bots
        if !request.all {
            let unknown = request.bots.filter { name in !bots.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            guard unknown.isEmpty else { return .failure(.unknownBots(unknown, known: bots.map(\.name))) }
            targets = bots.filter { bot in request.bots.contains { $0.caseInsensitiveCompare(bot.name) == .orderedSame } }
        }
        guard !targets.isEmpty else { return .failure(.noBots) }
        let programs = templates.map(\.label)
        var fixed: HerdrClient.Template? = nil
        if let runtime = request.runtime {
            guard let template = HerdrBotRequest.template(for: runtime, in: templates) else { return .failure(.noProgram(runtime, offered: programs)) }
            fixed = template
        }
        /// The model `template` would run: the recommended one, the one the request names, or why not. `typed`: an
        /// ID the server does not list is taken as written where the program takes one (OpenCode's provider/model).
        /// Only for a program the request names: an unlisted ID alone must not move bots to that program.
        func model(on template: HerdrClient.Template, typed: Bool = false) -> Result<(id: String, label: String), HerdrModelRefusal> {
            guard let wanted = request.model else { return .success((HerdrModelChoice.recommended, recommendedLabel)) }
            guard template.takesModel else { return .failure(.picksOwnModel(template.label)) }
            let listed = offered[template.name] ?? template.models ?? []
            switch HerdrModelRequest.match(wanted, in: listed) {
            case .one(let found): return .success((found.id, found.label ?? found.id))
            case .several(let found): return .failure(.severalModels(wanted, candidates: found.map(\.id)))
            case .none:
                if typed, template.modelAgent == "OpenCode", let id = HerdrModelChoice.apiModelID(wanted) { return .success((id, id)) }
                return .failure(.noModel(wanted, program: template.label, offered: listed.map(\.id)))
            }
        }
        /// Each target's template and model.
        var chosen: [(template: HerdrClient.Template, model: String)] = []
        let label: String
        if let fixed {
            switch model(on: fixed, typed: true) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): chosen = targets.map { _ in (fixed, found.id) }; label = "\(fixed.label) · \(found.label)"
            }
        } else if request.model == nil {
            // The recommended model of whatever program each bot runs.
            for target in targets {
                guard let own = templates.first(where: { $0.name == target.template }) else { return .failure(.whichProgram(recommendedLabel, programs: programs)) }
                chosen.append((own, HerdrModelChoice.recommended))
            }
            label = recommendedLabel
        } else {
            // No program named: the model says which. A model only one program offers moves every bot to that program.
            var hits: [(template: HerdrClient.Template, id: String, label: String)] = [], several: HerdrModelRefusal? = nil
            for template in templates where template.takesModel {
                switch model(on: template) {
                case .success(let found): hits.append((template, found.id, found.label))
                case .failure(let refusal): if case .severalModels = refusal { several = several ?? refusal }
                }
            }
            guard let first = hits.first else {
                return .failure(several ?? .noModel(request.model ?? "", program: nil, offered: templates.flatMap { offered[$0.name] ?? $0.models ?? [] }.map(\.id)))
            }
            if hits.count == 1 {
                chosen = targets.map { _ in (first.template, first.id) }; label = "\(first.template.label) · \(first.label)"
            } else {
                // Several programs offer it: each bot keeps its program, which must then be one of them.
                for target in targets {
                    guard let hit = hits.first(where: { $0.template.name == target.template }) else { return .failure(.whichProgram(request.model ?? "", programs: hits.map { $0.template.label })) }
                    chosen.append((hit.template, hit.id))
                }
                label = first.label
            }
        }
        var changes: [Change] = [], unchanged = 0
        for (target, choice) in zip(targets, chosen) {
            if target.template == choice.template.name, target.model == choice.model { unchanged += 1; continue }
            changes.append(Change(bot: target.id, name: target.name, template: choice.template.name, model: choice.model, beforeTemplate: target.ownTemplate, beforeModel: target.model))
        }
        return .success(HerdrModelPlan(changes: changes, unchanged: unchanged, label: label))
    }
}

/// Why a model request changed nothing. `text` says it to the person, and to the main bot so it can correct itself.
enum HerdrModelRefusal: Error, Equatable, Sendable {
    case noBots
    case unknownBots([String], known: [String])
    case noProgram(String, offered: [String])
    case noModel(String, program: String?, offered: [String])
    case severalModels(String, candidates: [String])
    case whichProgram(String, programs: [String])
    case picksOwnModel(String)
    case unreadable(String)

    /// A server that could not be read is not the request's fault: the request stays, to be applied later.
    var isTemporary: Bool { if case .unreadable = self { return true } else { return false } }

    var text: String {
        func list(_ items: [String], limit: Int = 30) -> String {
            guard !items.isEmpty else { return "none" }
            return items.prefix(limit).joined(separator: ", ") + (items.count > limit ? " and \(items.count - limit) more" : "")
        }
        switch self {
        case .noBots: return "There are no bots on this server to change."
        case .unknownBots(let names, let known): return "No bot here is named \(list(names)). The bots here: \(list(known))."
        case .noProgram(let name, let offered): return "The server has no agent program “\(name)”. It has: \(list(offered))."
        case .noModel(let name, let program, let offered): return "\(program ?? "No agent program on the server") has no model matching “\(name)”. Models\(program == nil ? " on the server" : ""): \(list(offered))."
        case .severalModels(let name, let candidates): return "“\(name)” matches several models: \(list(candidates)). Name one by its ID."
        case .whichProgram(let name, let programs): return "Not every bot runs an agent program that offers “\(name)”. Name the program to move them to: \(list(programs))."
        case .picksOwnModel(let program): return "\(program) picks its own model on this server, so no model can be set for it."
        case .unreadable(let why): return "The server could not be read: \(why)"
        }
    }
}
