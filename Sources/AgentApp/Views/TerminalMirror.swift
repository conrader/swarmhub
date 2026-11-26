import SwiftUI
import WebKit

/// Detached logs and older workspaces provide text without PTY dimensions. Show the latest 24 rows
/// in a nominal 80-column terminal. The web observer uses the live PTY's own geometry instead.
struct TerminalTextGrid: View {
    let output: String

    var body: some View {
        let rows = output.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line -> [String] in
            if line.isEmpty { return [""] }
            var rest = line
            var wrapped: [String] = []
            while !rest.isEmpty {
                let part = rest.prefix(80)
                wrapped.append(String(part))
                rest = rest[part.endIndex...]
            }
            return wrapped
        }.suffix(24)
        GeometryReader { geometry in
            let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let cell = ("0" as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: cell.width * 80, height: ceil(cell.height) * 24)
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    Text(verbatim: row.element).font(Font(font)).fixedSize()
                        .frame(height: ceil(cell.height), alignment: .leading)
                }
            }.frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }.clipped().background(AppColor.chat)
            .accessibilityRepresentation { Text(verbatim: rows.joined(separator: "\n")) }
    }
}

struct TerminalMirror: NSViewRepresentable {
    let url: URL
    let token: String
    let agent: HerdrClient.AgentRef
    let core: String?
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
        view.navigationDelegate = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let mirror: TerminalMirror
        init(_ mirror: TerminalMirror) { self.mirror = mirror }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.targetFrame?.isMainFrame == true && action.request.url == mirror.url ? .allow : .cancel
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard view.url == mirror.url else { return }
            view.callAsyncJavaScript("window.openTerminalPreview(address, created, token, core)", arguments: [
                "address": mirror.agent.address, "created": NSNumber(value: mirror.agent.createdMs),
                "token": mirror.token, "core": mirror.core as Any? ?? NSNull()
            ], in: nil, in: .page) { result in
                if case .failure(let error) = result { self.mirror.failed(error.localizedDescription) }
            }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            mirror.failed(error.localizedDescription)
        }
    }
}
