import SwiftUI
import WebKit

struct ComputerView: View {
    @AppStorage("noVNCURL") private var rawURL = ""
    var body: some View {
        if let url = URL(string: rawURL), !rawURL.isEmpty { WebView(url: url) }
        else { ContentUnavailableView("Computer not configured", systemImage: "display", description: Text("Add the agent’s noVNC URL in Settings.")) }
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateNSView(_ view: WKWebView, context: Context) { if view.url != url { view.load(URLRequest(url: url)) } }
}
