import SwiftUI

extension HerdrClient {
    /// `GET` and `POST /api/alerts` (`alerts.rs`): where the workspace posts what would raise a notification,
    /// so it reaches the person while no app is open. `test` is "sent" or why the address did not take a line.
    struct AlertAddress: Decodable, Sendable, Equatable {
        var address: String? = nil
        var test: String? = nil
    }

    func alertAddress() async throws -> AlertAddress { try await get("/api/alerts") }

    func setAlertAddress(_ address: String, test: Bool) async throws -> AlertAddress {
        try await post("/api/alerts", ["address": address, "test": test])
    }
}

/// Settings → Servers: the address the server posts alerts to. A server without this feature shows nothing.
struct HerdrAlertAddressBlock: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    @State private var supported = false
    @State private var address = ""
    @State private var saved = ""
    @State private var note = ""
    @State private var working = false

    var body: some View {
        Group {
            if supported {
                SettingBlock(title: "Alerts when SwarmHub is closed",
                             detail: "The server posts a short line here when a bot finishes a goal, needs your answer or misses a check-in. Use an address only you read, such as an ntfy topic or a Slack incoming webhook: the bot's name and the start of its message are sent to it.") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://ntfy.sh/your-topic", text: $address)
                            .textFieldStyle(.roundedBorder).disabled(working)
                            .accessibilityLabel("Alert address").accessibilityIdentifier("server.alertAddress")
                        HStack(spacing: 10) {
                            Button(address.trimmingCharacters(in: .whitespaces).isEmpty ? "Turn off" : "Save and send a test") { Task { await save() } }
                                .disabled(working || (address == saved && address.isEmpty))
                            if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
        }
        .task(id: server.id) {
            guard store.launchWorkEnabled, let client = try? store.herdrClient(for: server),
                  let current = try? await client.alertAddress() else { supported = false; return }
            supported = true
            saved = current.address ?? ""
            address = saved
        }
    }

    private func save() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let wanted = address.trimmingCharacters(in: .whitespaces)
        do {
            let answer = try await store.herdrClient(for: server).setAlertAddress(wanted, test: !wanted.isEmpty)
            saved = answer.address ?? ""
            address = saved
            note = saved.isEmpty ? "Alerts are off." : (answer.test == "sent" ? "Saved. A test line was sent." : "Saved, but the test did not arrive. \(answer.test ?? "")")
        } catch { note = error.localizedDescription }
    }
}
