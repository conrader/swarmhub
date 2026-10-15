import Foundation
import Testing
@testable import AgentApp

// P31 C: the manager text on demand and small. The core (`manager-hermes.md`) is the skill's SKILL.md body; the box and
// accounts recipes live in `recipes/` and ship as the skill's `references/`. A Hermes manager with the skill at any
// version gets a one-line pointer, one without it core + both recipes; SwarmHub's own turns carry only the recipe they
// need. Synthetic only; nothing reaches a box.

/// One distinctive line of each recipe, and of the core.
private let signatures: [String: String] = [
    "list": #"printf '{"op":"bots","list":[%s],"reports":[%s]}\n'"#,
    "adopt": #"printf '{"op":"bots_adopted","results":[%s]}\n'"#,
    "restore": #"printf '{"op":"key_restored","name":"%s","ok":%s}\n'"#,
    "status": "credential_pool",
    "install": "npm install -g --prefix ~/.local",
    "start": "HERMES_HOME=~/.hermes hermes auth add openai-codex",
    "link": #"printf '{"op":"login_link","tool":"%s","url":"%s","code":"%s"}\n'"#,
    "check": "while ! grep -q '^EXIT' $F",
    "code": #"[ "$R" = ok ] && R=true || R=false"#,
    "logout": "codex logout > /dev/null 2>&1",
    "models": #"printf '{"op":"models","list":[%s]}\n'"#,
    "capacity": #"printf '{"op":"box_capacity","cpus":%s,"#,
    "limit": #"echo "SLOTS=$N"; } > $F.swarmhub-new"#,
    "core": "hermes profile create"
]

private let coreLines = ["You are also Konrad's bot manager", "Avatars are a SwarmHub thing", "KM=model.default KP=model.provider", "```swarmhub"]

private func check(_ name: String, _ text: String?, carries wanted: Set<String>) throws -> Int {
    let text = try #require(text, "\(name)")
    for (recipe, line) in signatures {
        #expect(text.contains(line) == wanted.contains(recipe), "\(name): \(recipe) \(wanted.contains(recipe) ? "missing" : "must not ride along")")
    }
    for line in coreLines { #expect(!text.contains(line), "\(name) carries the core: \(line)") }
    print("P31C-SIZE \(name): \(text.utf8.count) bytes")
    return text.utf8.count
}

@Test @MainActor func coreAndRecipeFilesHoldTheirOwnRecipesWithinBudget() throws {
    let core = try #require(BotManagerText.template()), box = try #require(BotManagerText.recipe(.box))
    let accounts = try #require(BotManagerText.recipe(.accounts))
    let models = try #require(BotManagerText.recipe(.models)), capacity = try #require(BotManagerText.recipe(.capacity))
    // P31 D+E: the core keeps its size budget (the empty-pin skip check and one clause on clearing the pin).
    #expect(core.utf8.count <= 4_600, "core is \(core.utf8.count) bytes")
    #expect(models.utf8.count <= 1_000 && capacity.utf8.count <= 1_600, "models \(models.utf8.count), capacity \(capacity.utf8.count)")
    // P36: + the reports listing and "Close reports" (2,816 bytes).
    #expect(box.utf8.count <= 2_900 && accounts.utf8.count <= 4_000, "box \(box.utf8.count), accounts \(accounts.utf8.count)")
    print("P31C-SIZE core manager-hermes.md: \(core.utf8.count) bytes; recipes/box.md: \(box.utf8.count); recipes/accounts.md: \(accounts.utf8.count); recipes/models.md: \(models.utf8.count); recipes/capacity.md: \(capacity.utf8.count)")
    for line in coreLines { #expect(core.contains(line), "\(line)") }
    let parts = ["core": core, "box": box, "accounts": accounts, "models": models, "capacity": capacity]
    let owners = ["list": "box", "adopt": "box", "restore": "box", "core": "core", "models": "models", "capacity": "capacity", "limit": "capacity"]
    for (recipe, line) in signatures {
        let owner = owners[recipe] ?? "accounts"
        for (part, text) in parts { #expect(text.contains(line) == (part == owner), "\(recipe) in \(part)") }
    }
    for text in [box, accounts, models, capacity] { #expect(text.contains("{{") == (text == box) && text.contains("put exactly that line in your swarmhub block")) }
    let full = try #require(BotManagerText.fullTemplate())
    let joined = [core, box, accounts, models, capacity].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    #expect(full == joined + "\n")
    #expect(BotManagerText.fullTemplate(recipes: [box, nil]) == nil && BotManagerText.fullTemplate(core: nil) == nil)
    print("P31C-SIZE full text (no skill): \(full.utf8.count) bytes; pointer: \(AppStore.skillPointer.utf8.count) bytes")
}

@Test @MainActor func eachHiddenTurnCarriesOnlyItsRecipes() throws {
    let box = try #require(BotManagerText.recipe(.box)), accounts = try #require(BotManagerText.recipe(.accounts))
    let script = try #require(SkillLibrary.bundled().first { $0.name == "swarmhub-coding" }?.files.first { $0.path == AppStore.claudeLoginScript }?.content)
    var sizes: [String: Int] = [:]
    sizes["list"] = try check("discovery (list)", BoxAdoption.listInstructions(template: box, managerProfile: "grok-jarvis"), carries: ["list"])
    sizes["adopt"] = try check("adoption (connect)", BoxAdoption.adoptInstructions(template: box, managerProfile: "grok-jarvis", names: ["cfo"]), carries: ["adopt"])
    sizes["restore"] = try check("restore", BoxAdoption.restoreInstructions(template: box, managerProfile: "grok-jarvis", name: "cfo", backup: ""), carries: ["restore"])
    sizes["status"] = try check("accounts status", CodingAccounts.statusInstructions(template: accounts), carries: ["status"])
    sizes["install"] = try check("install", CodingAccounts.installInstructions(template: accounts), carries: ["install", "status"])
    for tool in CodingTool.allCases {
        let login = CodingAccounts.loginInstructions(tool, template: accounts, script: tool == .claude ? script : nil)
        sizes["login \(tool)"] = try check("login \(tool.rawValue)", login, carries: ["start", "link"])
        sizes["check \(tool)"] = try check("check \(tool.rawValue)", CodingAccounts.checkInstructions(tool, template: accounts), carries: ["check"])
    }
    sizes["code"] = try check("code", CodingAccounts.codeInstructions("good-code#st8", template: accounts), carries: ["code"])
    for tool in [CodingTool.claude, .codex] {
        sizes["logout \(tool)"] = try check("logout \(tool.rawValue)", CodingAccounts.logoutInstructions(tool, template: accounts), carries: ["logout", "status"])
    }
    let full = try #require(BotManagerText.fullTemplate()).utf8.count
    for (name, size) in sizes where name != "login claude" { #expect(size <= 2_600 && size < full / 2, "\(name): \(size) bytes, full text \(full)") }
    let claude = try #require(sizes["login claude"])
    #expect(claude <= script.utf8.count + 2_600, "the Claude login turn is its two recipes plus the bundled script: \(claude) bytes")
}

/// The store's turns read the recipe files themselves (no override), never the core or the full text.
@Test @MainActor func storeTurnsReadOnlyTheRecipeFiles() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    #expect(store.managerRecipeTemplate(.box) == BotManagerText.recipe(.box) && store.managerRecipeTemplate(.accounts) == BotManagerText.recipe(.accounts))
    store.managerTemplateOverride = "override"
    #expect(store.managerRecipeTemplate(.box) == "override")
}

/// Hermes: the pointer for the skill at any version (current or outdated), core + both recipes only without it.
@Test @MainActor func managementTurnSendsThePointerWheneverTheSkillIsInstalled() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", persona: "", backend: .hermes, hermesProfile: "grok-jarvis")
    store.bots = [jarvis]; store.setCanManageBots(jarvis, true)
    let skill = try #require(store.skillLibrary.first { $0.name == SkillLibrary.managerSkill })
    func turn() -> String? { store.managementExchanges = [:]; return store.managementText(for: jarvis, text: "list bots", conversation: jarvis) }
    let full = try #require(turn()), bundled = try #require(BotManagerText.fullTemplate())
    #expect(full == BotManagerText.filled(bundled, managerProfile: "grok-jarvis"), "missing → core + both recipes")
    for line in signatures.values { #expect(full.contains(line), "\(line)") }
    #expect(!full.contains("references/"), "the fallback has the recipes inline")
    for installed in ["1.0.0", "1.0.2", skill.version.description, "garbage"] {
        jarvis.installedSkills = [SkillLibrary.managerSkill: installed]
        #expect(turn() == AppStore.skillPointer, "\(installed)")
    }
    #expect(store.skillBanner(for: jarvis)?.state == .outdated(installed: "garbage"), "the Update banner still offers the upgrade")
}

/// The install turn writes SKILL.md (core + when to read each reference) and both references filled for the profile.
@Test @MainActor func installWritesTheReferencesFilledForTheProfile() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let skill = try #require(store.skillLibrary.first { $0.name == SkillLibrary.managerSkill })
    let text = try #require(try store.skillInstallInstructions([skill], profile: "grok-jarvis", botName: "Jarvis"))
    let folder = SkillLibrary.installPath(skill.name, profile: "grok-jarvis")
    #expect(text.contains("mkdir -p \(folder) \(folder)/references\n"))
    for recipe in BotManagerText.Recipe.allCases {
        let shipped = try #require(BotManagerText.recipe(recipe)), filled = BotManagerText.filled(shipped, managerProfile: "grok-jarvis")
        #expect(text.contains("cat > \(folder)/references/\(recipe.rawValue).md <<'SWARMHUB_EOF'\n\(filled)SWARMHUB_EOF"), "\(recipe)")
        #expect(text.contains("first read `\(folder)/references/\(recipe.rawValue).md`"))
    }
    #expect(!text.contains("{{") && !text.contains("chmod 755"), "references are not scripts")
    #expect(text.contains(#"{"name":"swarmhub-manager","version":"1.2.0"}"#))
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "grok-jarvis", managerTemplate: BotManagerText.template()))
    print("P31C-SIZE rendered SKILL.md (grok-jarvis): \(rendered.utf8.count) bytes; install turn: \(text.utf8.count) bytes")
}
