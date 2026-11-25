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
        defer { window.orderOut(nil) }
        var html = try String(contentsOf: web.appendingPathComponent("chat-terminal.html"), encoding: .utf8)
        let css = try String(contentsOf: web.appendingPathComponent("vendor/xterm.css"), encoding: .utf8)
        html = html.replacingOccurrences(of: #"<link rel="stylesheet" href="/vendor/xterm.css">"#, with: "<style>" + css + "</style>")
        // Install the mock before any production JS runs. The page has no network URL.
        html = html.replacingOccurrences(of: "<head>", with: """
        <head><script>
        window.fixtureSizes = [];
        window.WebSocket = class extends EventTarget {
          static OPEN = 1; readyState = 1; bufferedAmount = 0;
          constructor() { super(); setTimeout(() => this.dispatchEvent(new Event("open")), 0); }
          send(raw) {
            if (typeof raw !== "string") throw Error("Unexpected terminal input");
            const message = JSON.parse(raw);
            if (message.rows) fixtureSizes.push(message.rows);
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
        try await waitUntil { (try? await view.evaluateJavaScript("typeof openChatTerminal === 'function'") as? Bool) == true }
        _ = try await view.evaluateJavaScript("openChatTerminal('fixture','1','Doc','fixture')")
        try await waitUntil { (try? await view.evaluateJavaScript("fixtureSizes.length > 0") as? Bool) == true }
        let target = try #require(try await view.evaluateJavaScript("chatModelTerminal.heightForRows(24)") as? NSNumber)
        TerminalSheetSize.fit(window, webView: view, viewportHeight: target.doubleValue)
        try await waitUntil { (try? await view.evaluateJavaScript("fixtureSizes.at(-1) === 24 && chatModelTerminal.lines().length === 24") as? Bool) == true }
        let lines = try #require(try await view.evaluateJavaScript("chatModelTerminal.lines()") as? [String])
        #expect(lines.filter { !$0.isEmpty }.count > 3 && lines.joined().contains("2. Deny"))
        #expect(host.bounds.height > view.bounds.height)
        try snapshot(host, "terminal-24")
        window.setContentSize(NSSize(width: host.bounds.width, height: host.bounds.height - 90))
        try await waitUntil { (try? await view.evaluateJavaScript("fixtureSizes.at(-1) < 24 && fixtureSizes.at(-1) === chatModelTerminal.lines().length") as? Bool) == true }
        try snapshot(host, "terminal-resized")
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
