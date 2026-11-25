import SwiftUI
import WebKit

struct HerdrPickerTarget: Identifiable {
    let id = UUID()
    let record: HerdrModelConfirmation
    let agent: HerdrClient.AgentRef
    let program: String
}

struct HerdrTerminalTarget: Identifiable {
    let agent: HerdrClient.AgentRef
    var title: String? = nil
    var id: HerdrClient.AgentRef { agent }
}

struct HerdrTerminalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    let agent: HerdrClient.AgentRef
    var title: String? = nil
    var group: GroupChat? = nil
    var target: HerdrPickerTarget? = nil
    var didConfirm: (() -> Void)? = nil
    @State private var terminal: (url: URL, token: String)?
    @State private var error: String?

    var body: some View {
        let heading = title ?? bot.name
        TerminalSheetLayout(heading: heading) {
            if store.herdrPrompt(for: bot, in: group)?.agent == agent,
               let fallback = store.herdrPromptAnswer(for: bot, in: group) {
                Button(fallback.button) {
                    if !store.answerHerdrPrompt(for: bot, in: group) { error = "The external terminal could not be opened." }
                }.help(fallback.help)
            }
            Button("Done") { dismiss() }
        } content: {
            if let target {
                Text(target.program == "Claude Code" ? "Switching this conversation to \(target.record.label). If the picker does not open, type /model. Highlight the model and press the session-only shortcut." : "Choose \(target.record.label) in the running agent’s /model picker and confirm its options.")
                    .font(.callout)
            }
            if let error { Text(error).foregroundStyle(AppColor.caution).textSelection(.enabled) }
            if let terminal {
                TerminalSurface(url: terminal.url, token: terminal.token, agent: agent, name: heading, target: target, confirmed: {
                    guard let target else { return }
                    store.rememberModel(target.record, for: bot)
                    didConfirm?()
                    dismiss()
                }, failed: { error = $0 })
            } else if error == nil { ProgressView("Connecting…") }
        }
        .task {
            do {
                let server = store.herdrServer(for: bot)
                let connection = try store.herdrClient(for: server)
                if let target {
                    let workspace = try await connection.workspace()
                    let current = connection.liveAgent(named: HerdrBackend.agentName(botName: bot.name, botID: bot.id), in: workspace)
                    guard target.record.matches(server: server.id, core: workspace.core, agent: current?.ref),
                          workspace.templates.first(where: { $0.name == current?.template })?.modelAgent == target.program,
                          current?.status?.state != "working", current?.status?.state != "blocked" else {
                        throw BackendError.unavailable("The session changed or is busy. Try the model switch when it is ready.")
                    }
                }
                let url = try await connection.connectedBaseURL().appendingPathComponent("chat-terminal")
                try Task.checkCancellation()
                terminal = (url, connection.token)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct TerminalSheetLayout<Controls: View, Content: View>: View {
    let heading: String
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(heading).font(.headline)
                Spacer()
                controls()
            }
            content()
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 740, minHeight: 200, idealHeight: 490, maxHeight: .infinity)
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let url: URL
    let token: String
    let agent: HerdrClient.AgentRef
    let name: String
    let target: HerdrPickerTarget?
    let confirmed: () -> Void
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.attached = false
        view.navigationDelegate = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var attached = true
        var sized = false
        let terminal: TerminalSurface
        init(_ terminal: TerminalSurface) { self.terminal = terminal }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.targetFrame?.isMainFrame == true && action.request.url == terminal.url ? .allow : .cancel
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard view.url == terminal.url else { return }
            view.callAsyncJavaScript("""
                window.openChatTerminal(address, created, name, token);
                await document.fonts.ready;
                await new Promise(requestAnimationFrame);
                return window.chatModelTerminal.heightForRows?.(24);
                """,
                                     arguments: ["address": terminal.agent.address, "created": String(terminal.agent.createdMs),
                                                 "name": terminal.name, "token": terminal.token], in: nil, in: .page) { result in
                guard self.attached else { return }
                if case .success(let value) = result, let height = value as? NSNumber, !self.sized,
                   let window = view.window, !window.inLiveResize {
                    self.sized = true
                    TerminalSheetSize.fit(window, webView: view, viewportHeight: height.doubleValue)
                }
                if case .success = result, let target = self.terminal.target {
                    view.callAsyncJavaScript("return await window.chooseChatModel(program, id, label)", arguments: ["program": target.program, "id": target.record.id, "label": target.record.label], in: nil, in: .page) { response in
                        guard self.attached else { return }
                        if case .failure = response { self.terminal.failed("The provider has not confirmed the switch. Type /model in this terminal to check or choose the model.") }
                        if case .success(let confirmed) = response, confirmed as? Bool == true { self.terminal.confirmed() }
                    }
                }
                if case .failure = result { self.terminal.failed("This server could not open the chat terminal. Update the workspace or use the external terminal option.") }
            }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { terminal.failed(error.localizedDescription) }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { terminal.failed(error.localizedDescription) }
    }
}

@MainActor enum TerminalSheetSize {
    static func fit(_ sheet: NSWindow, webView: WKWebView, viewportHeight: CGFloat) {
        guard let screen = sheet.screen, viewportHeight.isFinite, viewportHeight > 0 else { return }
        var frame = sheet.frame
        let top = min(frame.maxY, screen.visibleFrame.maxY)
        let available = max(1, top - screen.visibleFrame.minY)
        let height = min(available, frame.height - webView.bounds.height + viewportHeight)
        frame.origin.y = top - height
        frame.size.height = height
        sheet.setFrame(frame, display: true)
    }
}
