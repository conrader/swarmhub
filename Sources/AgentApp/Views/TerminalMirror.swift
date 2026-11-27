import SwiftUI
import WebKit

/// Detached logs and older workspaces provide text without PTY dimensions. Show the latest 24 rows
/// in a nominal 80-column terminal. The web observer uses the live PTY's own geometry instead.
struct TerminalTextGrid: View {
    let output: String
    var scrollback = false
    var readable = false

    var body: some View {
        if readable {
            ScrollView {
                Text(verbatim: output)
                    .font(.system(size: 17, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }.defaultScrollAnchor(.bottom).background(AppColor.chat)
        } else {
            fittedGrid
        }
    }

    private var fittedGrid: some View {
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
        }
        return GeometryReader { geometry in
            let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let cell = ("0" as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: cell.width * 80, height: ceil(cell.height) * 24)
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            if scrollback {
                ScrollView {
                    Text(verbatim: rows.joined(separator: "\n"))
                        .font(.system(size: 14 * scale, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.defaultScrollAnchor(.bottom)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.suffix(24).enumerated()), id: \.offset) { row in
                        Text(verbatim: row.element).font(Font(font)).fixedSize()
                            .frame(height: ceil(cell.height), alignment: .leading)
                    }
                }.frame(width: size.width, height: size.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .accessibilityRepresentation { Text(verbatim: rows.suffix(24).joined(separator: "\n")) }
            }
        }.clipped().background(AppColor.chat)
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

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.mirror = self
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var mirror: TerminalMirror
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
