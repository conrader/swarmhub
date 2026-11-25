import SwiftUI

/// The bridge owns this work, including while the app is closed.
struct HerdrTeamActivity: View {
    @Environment(\.timeZone) private var timeZone
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var recent: [HerdrClient.TeamPage.Exchange] = []
    @State private var exchanges: [HerdrClient.TeamPage.Exchange] = []
    @State private var plans: [HerdrClient.BotCheckin] = []
    @State private var promises: [Promise] = []
    @State private var error = ""
    @State private var loaded = false
    @State private var busy = false

    private struct Promise: Decodable, Identifiable { let id: Int, what: String, dueMs: Int64, state: String }
    private struct Exchanges: Decodable { let exchanges: [HerdrClient.TeamPage.Exchange] }
    private struct Promises: Decodable { let promises: [Promise] }

    private var path: String { "/api/bots/\(bot.id.uuidString.lowercased())" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team activity").font(.headline).accessibilityAddTraits(.isHeader)
            if let syncError = store.teamErrors[store.herdrServer(for: bot).id] { Text(syncError).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).textSelection(.enabled) }
            if !loaded && error.isEmpty { ProgressView().controlSize(.small) }
            if loaded && recent.isEmpty && exchanges.isEmpty && plans.isEmpty && promises.isEmpty { Text("No open handoffs, check-ins or promises.").foregroundStyle(.secondary) }
            ForEach(exchanges) { exchangeRow($0) }
            if !exchanges.isEmpty {
                Button("Stop open exchanges") { change("stop", body: [:]) }
            }
            ForEach(plans) { plan in
                VStack(alignment: .leading) {
                    Text(plan.what)
                    if let url = plan.schedule.url { Text("Watching CI · \(url)").textSelection(.enabled) }
                    else if let next = plan.nextMs { Text("Check-in · \(date(next))") }
                    if plan.paused { Text("Paused") }
                    Button("Cancel check-in") { change("checkins/\(plan.id)/cancel", body: [:]) }
                }
            }
            ForEach(promises) { promise in
                VStack(alignment: .leading) {
                    Text(promise.what)
                    Text("Promised by \(date(promise.dueMs)) · \(promise.state)")
                    Button("Mark done") { change("promises/\(promise.id)/close", body: ["state": "done"]) }
                }
            }
            if !recent.isEmpty {
                Text("Recent exchanges").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(recent.prefix(3)) { exchangeRow($0) }
                if recent.count > 3 {
                    DisclosureGroup("Earlier exchanges") { ForEach(recent.dropFirst(3)) { exchangeRow($0) } }
                }
            }
        }.font(.callout).disabled(busy)
        .task(id: "\(bot.id)-\(store.herdrServer(for: bot).id)") {
            loaded = false; error = ""; plans = []; exchanges = []; recent = []; promises = []
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func exchangeRow(_ exchange: HerdrClient.TeamPage.Exchange) -> some View {
        DisclosureGroup("\(exchange.title) · \(exchange.state)") { Text(verbatim: exchange.text).textSelection(.enabled) }
    }

    private func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
    }

    private func load() async {
        do {
            let client = try store.herdrClient(for: store.herdrServer(for: bot))
            let base = path
            let botID = bot.id
            async let a: Exchanges = client.get(base + "/exchanges")
            async let b = client.botCheckins(botID)
            async let c: Promises = client.get(base + "/promises")
            async let history: Exchanges = client.get(base + "/exchanges?all=1")
            let results = try await (a, b, c, history)
            try Task.checkCancellation()
            exchanges = results.0.exchanges; plans = results.1; promises = results.2.promises
            recent = results.3.exchanges.filter { $0.state != "open" && $0.state != "accepted" }
            loaded = true; error = ""
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func change(_ suffix: String, body: [String: String]) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let client = try store.herdrClient(for: store.herdrServer(for: bot))
                let _: HerdrClient.TeamOK = try await client.post(path + "/" + suffix, body)
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }
}
