import Foundation

/// The recovery journal contains only server/core identifiers and operation IDs.
/// Both bridges fence late requests with those IDs, including cancellation before creation.
struct RoutineMoveReceipt: Codable {
    let token: UUID
    let owner: UUID
    let sourceCore: String
    let webhook: Bool
    let destinationCore: String
    var undoAttempt: UUID?
}

extension AppStore {
    private func receiptKey(from source: HerdrServer, to destination: HerdrServer) -> String {
        "herdr.routineMove.\(source.id).\(destination.id)"
    }

    func recoverRoutineMoveFromSettings(from source: HerdrServer, to destination: HerdrServer) async throws {
        guard !herdrMoveInProgress else { throw HerdrMoveError.selectionChanged }
        herdrMoveInProgress = true
        defer { herdrMoveInProgress = false; objectWillChange.send() }
        try await recoverRoutineMove(from: source, to: destination)
    }

    func recoverRoutineMove(from source: HerdrServer, to destination: HerdrServer) async throws {
        let key = receiptKey(from: source, to: destination)
        guard let data = defaults.data(forKey: key) else { return }
        let receipts = try JSONDecoder().decode([RoutineMoveReceipt].self, from: data)
        let (moved, remaining) = (receipts.filter { receipt in
            bots.contains { $0.id == receipt.owner && herdrServer(for: $0) == destination }
        }, receipts.filter { receipt in
            bots.contains { $0.id == receipt.owner && herdrServer(for: $0) == source }
        })
        guard moved.count + remaining.count == receipts.count else { throw HerdrMoveError.serversChanged }
        let recipient = try herdrClient(for: destination)
        for receipt in moved {
            let action = receipt.undoAttempt == nil ? "activate" : "resume"
            _ = try await recipient.transfer(receipt.token, .init(core: receipt.destinationCore, action: action, attempt: receipt.undoAttempt))
        }
        try await reverseRoutines(remaining, from: source, to: destination)
        defaults.removeObject(forKey: key)
    }

    func routineMovePending(from source: HerdrServer, to destination: HerdrServer) -> Bool {
        defaults.data(forKey: receiptKey(from: source, to: destination)) != nil
    }

    private func copyEvents(_ token: UUID, from origin: HerdrClient, core: String, to recipient: HerdrClient, destinationCore: String) async throws {
        var after = ""
        while true {
            let result = try await origin.transfer(token, .init(core: core, action: "events", after: after))
            guard let keys = result.digests else { throw HerdrMoveError.selectionChanged }
            guard let last = keys.last else { return }
            guard last > after else { throw HerdrMoveError.selectionChanged }
            _ = try await recipient.transfer(token, .init(core: destinationCore, action: "remember", digests: keys))
            after = last
        }
    }

    func reverseRoutines(_ receipts: [RoutineMoveReceipt], from source: HerdrServer, to destination: HerdrServer) async throws {
        guard !receipts.isEmpty else { return }
        let origin = try herdrClient(for: source), recipient = try herdrClient(for: destination)
        for receipt in receipts {
            _ = try await recipient.transfer(receipt.token, .init(core: receipt.destinationCore, action: "retire"))
        }
        for receipt in receipts {
            if receipt.webhook {
                try await copyEvents(receipt.token, from: recipient, core: receipt.destinationCore, to: origin, destinationCore: receipt.sourceCore)
            }
            _ = try await origin.transfer(receipt.token, .init(core: receipt.sourceCore, action: "restore"))
        }
    }

    func stageRoutines(_ record: HerdrServerMoveRecord, workspace: HerdrClient.Workspace,
                       destination: HerdrClient.Workspace) async throws -> [RoutineMoveReceipt] {
        let origin = try herdrClient(for: record.source), recipient = try herdrClient(for: record.destination)
        guard let core = workspace.core, let destinationCore = destination.core else { throw HerdrMoveError.serversChanged }
        let routines = try await origin.routines().filter { $0.state != .archived && $0.core == core }
        guard !routines.isEmpty else { return [] }
        let profiles = try await origin.profiles()
        var receipts: [RoutineMoveReceipt] = []
        var claimed = Set<Int64>()
        let candidates = bots.filter { $0.backend == .herdr && herdrServer(for: $0) == record.source }.map { bot in
            let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
            return (bot.id, name, HerdrRoutineSessions(agentName: name, workspace: workspace, profiles: profiles))
        }
        for change in record.changes {
            let name = HerdrBackend.agentName(botName: change.name, botID: change.botID)
            let owned = try routines.filter { item in
                if let owner = item.ownerBot { return owner == change.botID }
                let matches = candidates.filter { $0.2.contains(item) || HerdrRoutineSessions.matches(item.agent, $0.1) }
                if matches.count > 1 && matches.contains(where: { $0.0 == change.botID }) {
                    throw BackendError.unavailable("This routine has more than one possible owner. Rebind it before moving.")
                }
                return matches.first?.0 == change.botID
            }
            guard !owned.isEmpty else { continue }
            guard workspace.routineTransfers == true, destination.routineTransfers == true else {
                throw BackendError.unavailable("Update both workspace bridges before moving routines.")
            }
            guard !herdrBots(on: record.destination).contains(where: { peer in
                let peerName = HerdrBackend.agentName(botName: peer.name, botID: peer.id)
                return peer.id != change.botID && HerdrRoutineSessions.matches(peerName, name)
            }) else {
                throw BackendError.unavailable("A destination bot has a matching session identifier. Its routines could not be safely bound.")
            }
            var sessionClient = recipient
            sessionClient.expectedSessionCapCents = bots.first { $0.id == change.botID }?.sessionCapCents
            let warmed = try await sessionClient.warm(name: name, template: change.after.template,
                                                  model: change.after.model, workspaceID: change.botID)
            let target: HerdrClient.AgentRef
            switch warmed {
            case .running(let a, _), .started(let a, _):
                guard a.openCodeFirstTask != "uncertain", a.openCodeFirstTask != "not_sent", a.isLive else {
                    throw BackendError.unavailable("The destination workspace could not prepare the session for this bot’s routines.")
                }
                target = a.ref
            case .unavailable: throw BackendError.unavailable("Start the destination bot’s session before moving its routines.")
            }
            for routine in owned {
                try Task.checkCancellation()
                guard claimed.insert(routine.id).inserted else { throw HerdrMoveError.selectionChanged }
                let webhook = if case .webhook = routine.schedule { true } else { false }
                let receipt = RoutineMoveReceipt(token: UUID(), owner: change.botID, sourceCore: core, webhook: webhook, destinationCore: destinationCore)
                receipts.append(receipt)
                defaults.set(try JSONEncoder().encode(receipts), forKey: receiptKey(from: record.source, to: record.destination))
                let held = try await origin.transfer(receipt.token, .init(core: core, action: "hold", id: routine.id, target: routine.target))
                guard let item = held.routine, item.ownerBot == nil || item.ownerBot == change.botID else { throw HerdrMoveError.selectionChanged }
                _ = try await recipient.transfer(receipt.token, .init(core: destinationCore, action: "install", target: target,
                    name: item.name, task: item.task, schedule: item.schedule, state: item.state, nextAt: item.nextAt, owner: change.botID))
                if webhook { try await copyEvents(receipt.token, from: origin, core: core, to: recipient, destinationCore: destinationCore) }
            }
        }
        return receipts
    }

    func suspendRoutineMove(_ record: HerdrServerMoveRecord) async throws {
        guard !record.receipts.isEmpty else { return }
        try await recoverRoutineMove(from: record.source, to: record.destination)
        let recipient = try herdrClient(for: record.destination)
        let receipts = record.receipts.map { receipt in
            var undo = receipt
            undo.undoAttempt = UUID()
            return undo
        }
        defaults.set(try JSONEncoder().encode(receipts), forKey: receiptKey(from: record.source, to: record.destination))
        for receipt in receipts {
            _ = try await recipient.transfer(receipt.token, .init(core: receipt.destinationCore, action: "suspend", attempt: receipt.undoAttempt))
        }
    }
}
