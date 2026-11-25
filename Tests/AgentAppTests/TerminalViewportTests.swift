import AppKit
import SwiftUI
import Testing
import WebKit
@testable import AgentApp

/// Run on a logged-in Mac with swift test --filter TerminalViewportTests.
@MainActor struct TerminalViewportTests {
    @Test func wrappedPromptFitsAndResizesTheMockPTY() async throws {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HerdrWorkspace/web")
        let view = WKWebView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 490),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Doc · Terminal fixture"
        let host = NSHostingView(rootView: TerminalSheetLayout(heading: "Doc") {
            Button("Done") {}
        } content: { FixtureTerminal(view: view) })
        window.contentView = host
        window.center()
        window.orderFront(nil)
        defer { view.stopLoading(); window.orderOut(nil) }
        let screen = try #require(window.screen, "The terminal fixture needs a logged-in desktop.")
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: screen.visibleFrame.maxY))
        host.layoutSubtreeIfNeeded()
        var html = try String(contentsOf: web.appendingPathComponent("chat-terminal.html"), encoding: .utf8)
        let css = try String(contentsOf: web.appendingPathComponent("vendor/xterm.css"), encoding: .utf8)
        html = html.replacingOccurrences(of: #"<link rel="stylesheet" href="/vendor/xterm.css">"#, with: "<style>" + css + "</style>")
        // Install the mock before any production JS runs. The page has no network URL.
        html = html.replacingOccurrences(of: "<head>", with: """
        <head><script>
        window.fixtureSizes = [];
        window.fixtureRendered = false;
        window.WebSocket = class extends EventTarget {
          static OPEN = 1; readyState = 1; bufferedAmount = 0;
          constructor() { super(); setTimeout(() => this.dispatchEvent(new Event("open")), 0); }
          send(raw) {
            if (typeof raw !== "string") throw Error("Unexpected terminal input");
            const message = JSON.parse(raw);
            if (message.rows) fixtureSizes.push(message.rows);
            if (message.type === "credit") fixtureRendered = true;
            if (message.token) {
              this.dispatchEvent(new MessageEvent("message", {data:'{"type":"ready"}'}));
              const prompt = "Would you like to run the following command? " + "archived-fixture-directory/".repeat(12) + "\\r\\n1. Allow once\\r\\n2. Deny";
              this.dispatchEvent(new MessageEvent("message", {data:new TextEncoder().encode(prompt).buffer}));
            }
          }
          close() {}
        };
        </script>
        """)
        var scripts = ""
        for name in ["vendor/xterm.js", "vendor/addon-fit.js", "chat-model.js", "terminal.js"] {
            html = html.replacingOccurrences(of: "<script src=\"/\(name)\" defer></script>", with: "")
            let js = try String(contentsOf: web.appendingPathComponent(name), encoding: .utf8)
            scripts += "<script>" + js.replacingOccurrences(of: "</script", with: "<\\/script") + "</script>"
        }
        view.loadHTMLString(html.replacingOccurrences(of: "</body>", with: scripts + "</body>"), baseURL: nil)
        try await waitUntil(timeout: .seconds(10)) { !view.isLoading }
        _ = try await evaluate("typeof openChatTerminal === 'function'", in: view, until: { $0 as? Bool == true })
        _ = try await evaluate("openChatTerminal('fixture','1','Doc','fixture'); true", in: view)
        _ = try await evaluate("fixtureRendered && fixtureSizes.length > 0 && document.fonts.status === 'loaded'",
                               in: view, until: { $0 as? Bool == true })
        let target = try #require(try await evaluate("chatModelTerminal.heightForRows(24)", in: view) as? NSNumber)
        let needed = window.frame.height - view.bounds.height + target.doubleValue
        try #require(needed <= screen.visibleFrame.height, "The 24-row fixture needs \(needed) points of screen height.")
        TerminalSheetSize.fit(window, webView: view, viewportHeight: target.doubleValue)
        let rows = "[fixtureSizes.at(-1), chatModelTerminal.lines().length]"
        _ = try await evaluate(rows, in: view, until: { $0 as? [Int] == [24, 24] })
        let lines = try #require(try await evaluate("chatModelTerminal.lines()", in: view) as? [String])
        #expect(lines.filter { !$0.isEmpty }.count > 3 && lines.joined().contains("2. Deny"))
        #expect(host.bounds.height > view.bounds.height)
        try snapshot(host, "terminal-24")
        window.setContentSize(NSSize(width: host.bounds.width, height: host.bounds.height - 90))
        _ = try await evaluate(rows, in: view) { value in
            guard let sizes = value as? [Int], sizes.count == 2 else { return false }
            return sizes[0] > 0 && sizes[0] < 24 && sizes[0] == sizes[1]
        }
        try snapshot(host, "terminal-resized")
    }

    /// Poll the result on the main actor. A WebKit callback that never arrives must also hit the deadline.
    private func evaluate(_ script: String, in view: WKWebView, until matches: @escaping (Any?) -> Bool = { _ in true }) async throws -> Any? {
        var pending = false
        var result: Result<Any?, Error>?
        var last = "no WebKit response"
        do {
            try await waitUntil(timeout: .seconds(10)) {
                if let response = result {
                    switch response {
                    case .failure: return true
                    case .success(let value):
                        if matches(value) { return true }
                        last = String(describing: value)
                    }
                    result = nil
                }
                if !pending {
                    pending = true
                    view.evaluateJavaScript(script) { value, error in
                        if let error { result = .failure(error) } else { result = .success(value) }
                        pending = false
                    }
                }
                return false
            }
        } catch is WaitTimeout {
            throw FixtureTimeout(script: script, last: last, bounds: view.bounds)
        }
        return try #require(result).get()
    }

    private struct FixtureTimeout: Error, CustomStringConvertible {
        let script: String
        let last: String
        let bounds: CGRect
        var description: String { "Timed out evaluating \(script), last value \(last), web view \(bounds)" }
    }

    private struct FixtureTerminal: NSViewRepresentable {
        let view: WKWebView
        func makeNSView(context: Context) -> WKWebView { view }
        func updateNSView(_ view: WKWebView, context: Context) {}
    }

    private func snapshot(_ view: NSView, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SWARMHUB_FIXTURE_SHOTS"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
