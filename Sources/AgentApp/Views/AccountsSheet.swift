import AppKit
import SwiftUI

/// The connection an Accounts sheet is about (`AppStore.connection(of:)`) and its host for the title.
struct AccountsTarget: Identifiable, Equatable { let id: String; let host: String }

/// P31 C: Settings → Advanced → Servers and keys → the connection → Accounts…, and the bot editor's Coding agent area.
/// Claude Code, Codex CLI and the ChatGPT pool on that box: status, Install, Log in (link + device code, or Claude's
/// single-use code field), Log out, Refresh. Every action is a quiet manager turn; no token is ever shown.
struct AccountsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: AccountsTarget
    /// Renders and tests: no turn on appear.
    var refreshesOnAppear = true
    @State private var claudeCode = ""

    private var state: AccountsState { store.accounts(on: target.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(AccountsCopy.title) · \(target.host)").font(.title3.weight(.semibold))
            Text(AccountsCopy.intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(CodingTool.allCases) { tool in
                row(tool)
                if tool != .chatgpt { Divider() }
            }
            if let problem = state.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                if let running = state.running {
                    ProgressView().controlSize(.small)
                    Text(Self.runningText(running)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { act(.refresh) }.disabled(!state.allows(.refresh))
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { if refreshesOnAppear, state.report == nil { await store.runAccounts(.refresh, on: target.id) } }
    }

    @ViewBuilder private func row(_ tool: CodingTool) -> some View {
        let phase = state.phase(tool)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).fontWeight(.medium)
                    Text(AccountsCopy.status(tool, state, now: store.now())).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if phase == .missing { Button("Install") { act(.install) }.disabled(!state.allows(.install)) }
                if tool == .chatgpt, phase != .unknown { Button(phase == .loggedIn ? "Add account" : "Log in") { act(.login(tool)) }.disabled(!state.allows(.login(tool))) }
                if tool != .chatgpt, phase == .loggedOut { Button("Log in") { act(.login(tool)) }.disabled(!state.allows(.login(tool))) }
                if phase == .loggedIn, tool != .chatgpt { Button("Log out") { act(.logout(tool)) }.disabled(!state.allows(.logout(tool))) }
            }
            if tool == .chatgpt, phase != .unknown { Text(AccountsCopy.chatgptHelp).font(.caption).foregroundStyle(.secondary) }
            if let link = state.links[tool] { linkPanel(tool, link) }
        }
    }

    @ViewBuilder private func linkPanel(_ tool: CodingTool, _ link: AccountsState.Link) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tool == .claude ? "1. Open this page and sign in to Claude:" : "1. Open this page and sign in:").font(.callout)
            HStack {
                Text(link.url.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Open in browser") { NSWorkspace.shared.open(link.url) }
                Button("Copy") { copy(link.url.absoluteString) }
            }
            if tool == .claude {
                Text("2. Paste the code the page shows. It works once; \(AppConstants.name) passes it to the box and forgets it.").font(.callout)
                HStack {
                    SecureField("Code from the page", text: $claudeCode).textFieldStyle(.roundedBorder).onSubmit(sendCode)
                    Button("Send code", action: sendCode).disabled(claudeCode.isEmpty || !state.allows(.code))
                }
            } else {
                if let code = link.code {
                    HStack {
                        Text("2. Enter this code there:").font(.callout)
                        Text(code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                        Button("Copy") { copy(code) }
                    }
                }
                HStack {
                    Text(state.stillWaiting.contains(tool) ? AccountsCopy.waiting(tool) : "\(AppConstants.name) checks when you are done.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check") { act(.check(tool)) }.disabled(!state.allows(.check(tool)))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// The code goes into one hidden manager turn; the field is cleared before the turn starts.
    private func sendCode() {
        let code = claudeCode.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeCode = ""
        guard !code.isEmpty else { return }
        Task { await store.runAccounts(.code, on: target.id, code: code) }
    }

    private func act(_ action: AccountsState.Action) { Task { await store.runAccounts(action, on: target.id) } }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    static func runningText(_ action: AccountsState.Action) -> String {
        switch action {
        case .refresh: "Asking the box…"
        case .install: "Installing Claude Code and Codex CLI. This can take a few minutes…"
        case .login(let tool): "Starting the \(tool.title) login…"
        case .check: "Waiting for you to finish signing in…"
        case .code: "Sending the code…"
        case .logout(let tool): "Logging \(tool.title) out…"
        }
    }
}

/// The "Accounts…" button that opens the sheet for one connection.
struct AccountsButton: View {
    let target: AccountsTarget
    var title = "Accounts…"
    @EnvironmentObject private var store: AppStore
    @State private var shown: AccountsTarget?
    var body: some View {
        Button(title) { shown = target }.sheet(item: $shown) { AccountsSheet(target: $0).environmentObject(store) }
    }
}
