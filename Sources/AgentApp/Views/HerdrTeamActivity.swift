import SwiftUI

/// The bridge owns this work, including while the app is closed.
struct HerdrTeamActivity: View {
    @Environment(\.timeZone) private var timeZone
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var expanded = false
    @State private var exchanges: [HerdrClient.TeamPage.Exchange] = []
    @State private var plans: [Plan] = []
    @State private var promises: [Promise] = []
    @State private var error = ""
    @State private var loaded = false
    @State private var busy = false

    private struct Plan: Decodable, Identifiable {
        struct Schedule: Decodable { let url: String? }
        let id: Int, what: String, paused: Bool, schedule: Schedule, nextMs: Int64?
    }
    private struct Promise: Decodable, Identifiable { let id: Int, what: String, dueMs: Int64, state: String }
    private struct Exchanges: Decodable { let exchanges: [HerdrClient.TeamPage.Exchange] }
    private struct Plans: Decodable { let checkins: [Plan] }
    private struct Promises: Decodable { let promises: [Promise] }

    private var path: String { "/api/bots/\(bot.id.uuidString.lowercased())" }

    var body: some View {
        DisclosureGroup("Team activity", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let syncError = store.teamErrors[store.herdrServer(for: bot).id] { Text(syncError).foregroundStyle(.secondary) }
                if !error.isEmpty { Text(error).textSelection(.enabled) }
                if !loaded && error.isEmpty { ProgressView().controlSize(.small) }
                if loaded && exchanges.isEmpty && plans.isEmpty && promises.isEmpty { Text("No open handoffs, check-ins or promises.").foregroundStyle(.secondary) }
                ForEach(exchanges) { exchange in
                    DisclosureGroup("\(exchange.title) · \(exchange.state)") { Text(exchange.text).textSelection(.enabled) }
                }
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
            }.font(.callout).disabled(busy)
        }
        .task(id: "\(expanded)-\(bot.id)-\(store.herdrServer(for: bot).id)") {
            guard expanded else { return }
            loaded = false; plans = []; exchanges = []; promises = []
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
    }

    private func load() async {
        do {
            let client = try store.herdrClient(for: store.herdrServer(for: bot))
            let base = path
            async let a: Exchanges = client.get(base + "/exchanges")
            async let b: Plans = client.get(base + "/checkins")
            async let c: Promises = client.get(base + "/promises")
            let results = try await (a, b, c)
            try Task.checkCancellation()
            exchanges = results.0.exchanges; plans = results.1.checkins; promises = results.2.promises
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
