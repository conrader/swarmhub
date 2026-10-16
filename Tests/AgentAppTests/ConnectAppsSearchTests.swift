import Foundation
import Testing
@testable import AgentApp

/// P48 item 4: the Connect apps search field. The pause is released by hand (`Pauses`); nothing sleeps, and Composio
/// is `MockHermesProtocol`.
@MainActor private final class Pauses {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait(_ pause: Duration) async { await withCheckedContinuation { waiting.append($0) } }
    /// Lets the scheduled searches reach their pause, then ends every pause.
    func release() async {
        for _ in 0..<1_000 where waiting.isEmpty { await Task.yield() }
        let all = waiting; waiting = []; all.forEach { $0.resume() }
    }
}

private func toolkit(_ slug: String, _ name: String) -> ComposioToolkit {
    ComposioToolkit(.object(["slug": .string(slug), "name": .string(name)]))!
}

@MainActor @Test func typingFiltersTheTilesAtOnceAndSearchesTheCatalogOnlyAfterThePause() async throws {
    let pauses = Pauses(); var asked: [String] = []
    let search = ConnectAppsSearch(wait: { await pauses.wait($0) }, find: { term in
        asked.append(term); return [toolkit("googlecalendar", "Google Calendar"), toolkit("calendly", "Calendly")]
    })
    let tiles = ComposioToolkit.popular
    search.text = "c"; search.text = "ca"; search.text = "cal"
    #expect(search.local(tiles).map(\.id) == ["googlecalendar"], "the shown tiles filter at once")
    #expect(search.loading && asked.isEmpty && search.more(than: search.local(tiles)).isEmpty && !search.nothingMatches(local: search.local(tiles)))
    await pauses.release(); await search.settle()
    #expect(asked == ["cal"], "only the last term reaches the catalog, once")
    #expect(!search.loading && search.more(than: search.local(tiles)).map(\.id) == ["calendly"], "catalog matches not already shown go below")

    search.clear()
    #expect(search.text.isEmpty && !search.loading && search.local(tiles) == tiles && search.more(than: tiles).isEmpty)
    for _ in 0..<20 { await Task.yield() }
    #expect(pauses.count == 0 && asked == ["cal"], "clearing schedules nothing")
}

@MainActor @Test func nothingMatchesOnlyAfterTheCatalogSearchFindsNothing() async throws {
    let pauses = Pauses()
    let search = ConnectAppsSearch(wait: { await pauses.wait($0) }, find: { _ in [] })
    search.text = "zzz"
    let local = search.local(ComposioToolkit.popular)
    #expect(local.isEmpty && !search.nothingMatches(local: local), "still searching the catalog")
    await pauses.release(); await search.settle()
    #expect(search.nothingMatches(local: local))
    search.text = "zzzz"
    #expect(!search.nothingMatches(local: search.local(ComposioToolkit.popular)), "a new term waits for its own search")
    await pauses.release(); await search.settle()
}

@MainActor @Test func theCatalogSearchLeavesTheSheetsTilesAndConnectedAppsShowUnderTheirName() async throws {
    let (apps, host, _) = composioFixture { request in
        if request.url!.path.hasSuffix("toolkits") {
            let term = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" }?.value ?? ""
            return (200, ["items": term.isEmpty ? [["slug": "gmail", "name": "Gmail"]] : [["slug": "calendly", "name": "Calendly"]]])
        }
        if request.url!.path.hasSuffix("connected_accounts") { return (200, ["items": [composioAccount("ca_linear", toolkit: "linear")], "next_cursor": NSNull()]) }
        return composioHandler(request)
    }
    await apps.refresh(); await apps.search("")
    let before = ConnectAppsModal.tiles(apps)
    #expect(await apps.catalogMatches("cal").map(\.id) == ["calendly"])
    #expect(ConnectAppsModal.tiles(apps) == before, "the catalog search does not replace the tiles")
    #expect(before.prefix(ComposioToolkit.popular.count).map(\.id) == ComposioToolkit.popular.map(\.id))
    #expect(before.contains { $0.id == "linear" }, "a connected app outside the popular ones is a tile, so the filter finds it")
    #expect(MockHermesProtocol.recorded(host).contains { $0.url!.query?.contains("search=cal") == true })
}
