import SwiftUI
import WebKit

/// The right panel's Computer tab: the bot's web desktop address, whether it answers, and Take over
/// (a separate window with the page) or Open in browser.
struct ComputerTab: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var bot: Bot
    @State private var reachability = ComputerURL.Reachability.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Computer").font(.headline)
            ComputerURLField(bot: bot)
            if let url = ComputerURL.validURL(bot.computerURL) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { check(url) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Check again").disabled(reachability == .checking)
                }
                HStack {
                    Button("Open in browser") { NSWorkspace.shared.open(url) }
                    Spacer()
                    Button("Take over") { openWindow(id: ComputerWindow.id, value: bot.id) }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("Add the address of this bot’s web desktop (for example a noVNC page) to watch it and take over.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: bot.computerURL) { if let url = ComputerURL.validURL(bot.computerURL) { check(url) } else { reachability = .unknown } }
    }

    private var statusColor: Color {
        switch reachability { case .reachable: .green; case .unreachable: .red; default: .secondary }
    }
    private var statusText: String {
        switch reachability {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .reachable(let code): "Reachable (HTTP \(code))"
        case .unreachable(let reason): "Not reachable: \(reason)"
        }
    }
    private func check(_ url: URL) {
        reachability = .checking
        Task { reachability = await ComputerURL.probe(url) }
    }
}

/// Edits `bot.computerURL`; only an empty or valid address is saved.
struct ComputerURLField: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("https://desktop.example.com/vnc.html", text: $text).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save", action: save).disabled(!canSave)
            }
            if case .invalid(let reason) = ComputerURL.check(text) { Text(reason).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { text = bot.computerURL ?? "" }
        .onChange(of: bot.id) { _, _ in text = bot.computerURL ?? "" }
    }

    private var canSave: Bool {
        if case .invalid = ComputerURL.check(text) { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) != (bot.computerURL ?? "")
    }
    private func save() {
        switch ComputerURL.check(text) {
        case .empty: bot.computerURL = nil
        case .valid: bot.computerURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .invalid: return
        }
        store.objectWillChange.send(); store.save()
    }
}

/// Settings → Computers: one desktop address per bot.
struct SettingsComputersPane: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Section {
            Text("Each bot can have a web desktop (noVNC or similar). Use https, or http only for localhost. Keep passwords out of the address; the desktop page asks for them.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Bots") {
            ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in
                VStack(alignment: .leading, spacing: 4) { Text(bot.name).fontWeight(.medium); ComputerURLField(bot: bot) }
            }
        }
    }
}

/// "Take over": a separate window showing the bot's desktop page.
struct ComputerWindow: View {
    static let id = "computer"
    @EnvironmentObject private var store: AppStore
    let botID: UUID?

    var body: some View {
        if let bot = store.bots.first(where: { $0.id == botID }), let url = ComputerURL.validURL(bot.computerURL) {
            WebView(url: url).navigationTitle("\(bot.name) — Computer")
        } else {
            ContentUnavailableView("Computer not configured", systemImage: "display", description: Text("Add the bot’s desktop address in its Computer tab or in Settings → Computers."))
        }
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL
    /// The address last requested, so in-page navigation (noVNC rewrites its hash) never triggers a reload.
    final class Coordinator { var loaded: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { let view = WKWebView(); updateNSView(view, context: context); return view }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url; view.load(URLRequest(url: url))
    }
}
