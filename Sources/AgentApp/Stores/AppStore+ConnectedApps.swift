import Foundation

/// P38 B: connected apps on the store: the chat stream wrapper, the app connection card's bot, the decisions of app
/// action cards, and the SwarmHub connection service's state for the Settings pane.
extension AppStore {
    /// An app action card SwarmHub made itself (the chat tool loop, the worker inbox): decided by SwarmHub, never by the
    /// bot's server, a rule or a reviewer; it always asks you. Looked up by card id, never by the card's own fields.
    func isAppAction(_ approval: ApprovalRequest) -> Bool { connectedApps.localApprovals[approval.id] != nil }

    func makeConnectedApps() -> ConnectedAppsStore {
        let provisioner = connectedAppsServiceURL.map { ComposioProvisioningClient(baseURL: $0, identity: connectedAppsIdentity(url: $0)) }
        return ConnectedAppsStore(directory: fileURL.deletingLastPathComponent(), keyStore: keyStore, provisioner: provisioner, persistenceEnabled: persistenceEnabled)
    }

    /// The build's SwarmHub connection service (Info.plist `SWComposioProvisioningURL`); nil in tests and `swift run`.
    var connectedAppsServiceURL: URL? { ComposioProvisioningClient.configuredURL() }

    func connectedAppsIdentity(url: URL) -> SwarmHubAccountIdentity {
        SwarmHubAccountIdentity(center: reportsCenter, service: SwarmHubService(baseURL: url, session: reportsCenter.session))
    }

    /// The chat view supplies this identity. A card never falls back to the currently selected bot.
    func connectionBot(id: UUID?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id && !$0.isReadOnlyArchive && !$0.isDemo && $0.backend == .hermes }
    }

    /// A Hermes bot's turn goes through the connected-apps loop; so does any workflow task's turn (P38 E, its workflow
    /// operations); anything else is sent as it was.
    func conversationStream(_ request: AgentRequest, bot: Bot, backend: any AgentBackend) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let workflow = try workflowTools(for: request, bot: bot)
        guard connectionBot(id: bot.id) != nil || workflow != nil else { return try await backend.send(request) }
        return try await ConnectedAppsChat.stream(request, botID: bot.id, backend: backend, apps: connectedApps, workflow: workflow)
    }

    /// An app action card's answer: a chat action goes to the waiting tool loop, a background one to the SwarmHub
    /// service. Never to the bot's server.
    func decideAppAction(_ approval: ApprovalRequest, approved: Bool) async {
        guard let origin = connectedApps.localApprovals[approval.id],
              let bot = approval.botID.flatMap({ id in bots.first { $0.id == id } }) else { approvals.removeAll { $0.id == approval.id }; return }
        if case .background(let id) = origin {
            do {
                guard let client = backgroundExecutionClient() else { throw ComposioProvisioningError.unavailable }
                _ = try await client.request("requests/\(id)/decision", body: .object(["approved": .bool(approved)]))
                connectedApps.localApprovals[approval.id] = nil
            } catch { errorMessage = error.localizedDescription; return }
        } else if await !connectedApps.approvals.decide(approval.id, approved: approved) {
            approvals.removeAll { $0.id == approval.id }; errorMessage = "This app action is no longer waiting for approval."; return
        }
        approvals.removeAll { $0.id == approval.id }
        appendAudit(to: bot, approval: approval, outcome: approved ? .approved : .denied, decidedBy: "user", reason: "User chose " + (approved ? "approve." : "deny."))
        approvalConversation(approval, bot: bot).messages.append(ChatMessage(role: .system, content: approved ? "Approved: \(approval.title)" : "Declined: \(approval.title)"))
        objectWillChange.send(); save()
    }

    /// `swarmhub://app-connections/sign-in?…`: the browser handing back after the SwarmHub sign-in. The sign-in itself
    /// finishes by polling the server (`SwarmHubSignIn`), so the link only brings SwarmHub forward and re-reads the apps
    /// a pending Composio link may have connected. Any other `swarmhub://` link is ignored.
    @discardableResult func handleIncomingURL(_ url: URL) -> Bool {
        guard Self.isSignInReturn(url) else { return false }
        if connectedApps.hasKey, connectedApps.pendingLink != nil { Task { await connectedApps.refresh() } }
        return true
    }

    nonisolated static func isSignInReturn(_ url: URL) -> Bool {
        url.scheme == "swarmhub" && url.host == "app-connections" && url.path == "/sign-in" && url.user == nil && url.password == nil
    }

    // MARK: Background app access

    func backgroundExecutionClient() -> BackgroundExecutionClient? {
        connectedAppsServiceURL.map { BackgroundExecutionClient(baseURL: $0, identity: connectedAppsIdentity(url: $0), session: reportsCenter.session) }
    }

    /// The worker inbox: actions waiting for you become approval cards in their bot's chat (P37 cards, always asked).
    @discardableResult func refreshBackgroundInbox(client: BackgroundExecutionClient? = nil) async throws -> [ComposioValue] {
        guard let client = client ?? backgroundExecutionClient() else { throw ComposioProvisioningError.unavailable }
        let rows = try await client.request("inbox")["requests"].array ?? []
        for row in rows where row["state"].string == "awaitingApproval" {
            guard let requestID = row["id"].string, ComposioClient.validIdentifier(requestID), !approvals.contains(where: { $0.requestID == requestID }),
                  let bot = bots.first(where: { $0.id.uuidString.lowercased() == row["bot_id"].string?.lowercased() }) else { continue }
            let tool = row["tool"].string ?? "App action"
            let command = (try? row["arguments"].text()) ?? "{}"
            let approval = ApprovalRequest(id: UUID(), title: tool, summary: "Background · \(row["account"].string ?? "account")", draft: command, command: command,
                                           requestID: requestID, botID: bot.id, actionKind: "background.\(tool)")
            connectedApps.localApprovals[approval.id] = .background(requestID: requestID)
            routeAppApproval(approval, for: bot)
        }
        return rows
    }

    /// The SwarmHub connection service's `/health`: a 503 means sign-in is not set up on the server yet.
    func checkConnectedAppsService() async {
        guard let url = connectedAppsServiceURL else { connectedApps.serviceNote = nil; return }
        var request = URLRequest(url: url.appending(path: "health"), timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let status = ((try? await reportsCenter.session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
        connectedApps.serviceNote = status == 503 ? ConnectedAppsCopy.signInNotSetUp : nil
    }
}
