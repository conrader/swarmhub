import Foundation

/// What the sheet says about where a conversation lands, and what it remembers about a stop by Grok's service.
extension GrokImportCoordinator {
    func destination(for item: GrokFoundItem) -> String {
        let refreshedName = PreparedGrokBundle.cleanIdentity(item.name)
        if item.isGroup {
            let group = store.groups.first { $0.grokSourceID == item.id }
            let name = group.flatMap { refreshIdentity ? nil : $0.name } ?? refreshedName
            let hidden = group?.isHidden ?? item.hiddenInGrok
            let operation = group == nil ? "New group" : (refreshIdentity ? "Update group name and history" : "Update group history")
            let members = (group.map { store.members(of: $0).map(\.name) } ?? item.memberNames).joined(separator: ", ")
            return "\(operation) · “\(name)” · \(hidden ? "Hidden chats" : "sidebar")" + (members.isEmpty ? "" : " · \(members)")
        }
        let bot = store.bots.first { $0.grokSourceID == item.id }
        let name = bot.flatMap { refreshIdentity ? nil : $0.name } ?? AppStore.importedGrokName(refreshedName)
        let hidden = bot?.isHidden ?? item.hiddenInGrok
        let location = hidden ? "Hidden chats" : "the sidebar"
        let server = bot.map { store.herdrServer(for: $0).name } ?? serverName
        if !hasServer { return "“\(name)” in \(location) · runs after server setup" }
        if let bot {
            let reading = store.herdrProgramName(for: bot) ?? store.herdrTemplate(for: bot) ?? "current program"
            let action = refreshIdentity ? "Update history and bot identity" : "Update history"
            return "\(action) · “\(name)” · \(server) · \(reading) · \(location)"
        }
        let program = destinationPlan?.program(for: item.id)
        let model = program.flatMap { HerdrModelChoice.suggested(program: $0.modelAgent ?? $0.name, offered: $0.models) }
        let runtime = [program?.name, model.map(HerdrProgram.modelName)].compactMap { $0 }.joined(separator: " · ")
        return "New bot · “\(name)” · \(server) · \(runtime.isEmpty ? "Herdr agent" : runtime) · \(location)"
    }

    // MARK: A stop by Grok's service

    /// All history gave way to the recent messages for the rest of this run: shown now, and remembered for the next
    /// sheet session when it is a stop that will be there again (not this app's own limits).
    func fallBack(_ error: GrokServerError) {
        fallback = error
        guard error.isLastingRefusal else { return }
        let note = GrokRefusalNote(date: environment.now(), summary: error.userSummary, account: accountID)
        note.save(store.defaults)
        lastRefusal = note
    }

    /// The seconds the macOS window has been up: its own count, not the run's (which may have run and paused before).
    var waitingSeconds: Int {
        guard case .awaitingMacOS(let since) = step else { return 0 }
        return max(0, Int(Date().timeIntervalSince(since)))
    }

    /// All history worked again: the next sheet session opens on it.
    func forgetRefusal() {
        GrokRefusalNote.clear(store.defaults)
        lastRefusal = nil
    }

    /// One sentence about the remembered stop for the Found step.
    var refusalNote: String? {
        guard let lastRefusal else { return nil }
        let day = lastRefusal.date.formatted(date: .abbreviated, time: .omitted)
        return "All history was stopped by Grok on \(day). \(lastRefusal.summary) Recent messages still import; choose All history to try again."
    }
}
