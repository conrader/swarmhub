import Foundation
import Testing
@testable import AgentApp

/// P48 item 4: which bots use each account in the Connect apps sheet, and its per-bot switches (Agent access's
/// `setAllowed`, the 10-per-app cap). Composio is `MockHermesProtocol`; nothing reaches the network.
@MainActor @Test func eachAccountShowsTheBotsItIsOnForAndItsSwitchesChangeAgentAccess() async throws {
    let (apps, _, _) = composioFixture(); await apps.refresh()
    let jarvis = Bot(name: "Jarvis", backend: .hermes), infra = Bot(name: "Infra", backend: .hermes), cfo = Bot(name: "Cfo", backend: .hermes)
    let bots = [jarvis, infra, cfo]
    let work = try #require(apps.accounts.first { $0.id == "ca_work" }), personal = try #require(apps.accounts.first { $0.id == "ca_personal" })
    #expect(apps.bots(using: work, among: bots).isEmpty)
    #expect(ConnectedAppsCopy.usedBy([]) == "Not used by any bot")

    // The popover's switches are Agent access's: two Gmails used by different bots.
    apps.setAllowed(true, account: work, botID: jarvis.id); apps.setAllowed(true, account: work, botID: infra.id)
    apps.setAllowed(true, account: personal, botID: cfo.id)
    #expect(ConnectedAppsCopy.usedBy(apps.bots(using: work, among: bots).map(\.name)) == "Used by Jarvis, Infra")
    #expect(ConnectedAppsCopy.usedBy(apps.bots(using: personal, among: bots).map(\.name)) == "Used by Cfo")
    apps.setAllowed(false, account: work, botID: infra.id)
    #expect(apps.bots(using: work, among: bots).map(\.name) == ["Jarvis"] && apps.grants(for: infra.id).isEmpty)
    #expect(apps.canAllow(work, botID: infra.id) && apps.canAllow(personal, botID: jarvis.id))
}

@MainActor @Test func theSwitchRespectsTheTenAccountsPerAppCap() async throws {
    let ids = (1...11).map { "ca_mail_\($0)" }
    let (apps, _, _) = composioFixture { request in
        request.url!.path.hasSuffix("connected_accounts") ? (200, ["items": ids.map { composioAccount($0) }, "next_cursor": NSNull()]) : composioHandler(request)
    }
    await apps.refresh()
    let bot = Bot(name: "Jarvis", backend: .hermes)
    for account in apps.accounts.prefix(10) { apps.setAllowed(true, account: account, botID: bot.id) }
    let eleventh = try #require(apps.accounts.first { $0.id == "ca_mail_11" })
    #expect(!apps.canAllow(eleventh, botID: bot.id), "the eleventh switch is off and disabled")
    #expect(apps.canAllow(apps.accounts[0], botID: bot.id), "an account already on can stay on")
    apps.setAllowed(true, account: eleventh, botID: bot.id)
    #expect(apps.grants(for: bot.id).count == 10 && apps.error == ConnectedAppsCopy.accountsPerAppCap)
    apps.setAllowed(false, account: apps.accounts[0], botID: bot.id)
    #expect(apps.canAllow(eleventh, botID: bot.id))
}
