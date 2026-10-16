import AppKit
import SwiftUI

/// P48: where app logos come from. Views read it from the environment; tests and renders inject a fake, so they never
/// load a real logo.
@MainActor protocol AppLogoLoading: AnyObject {
    func image(for url: URL) async -> NSImage?
}

/// Loads `meta.logo` images: https only, only from Composio's logo host, at most 512 KB, an image type, kept in memory
/// for the run. Any failure is nil, and the tile shows its letter instead. A test run's session refuses the network
/// (`TestRunGuard`).
@MainActor final class AppLogoLoader: AppLogoLoading {
    static let shared = AppLogoLoader()
    nonisolated static let hosts: Set<String> = ["logos.composio.dev"]
    nonisolated static let byteLimit = 512 * 1024
    nonisolated static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && hosts.contains(url.host?.lowercased() ?? "") && url.user == nil && url.password == nil && url.port == nil
    }

    private let session: URLSession
    private var cache: [URL: NSImage] = [:]; private var failed: Set<URL> = []
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    init(session: URLSession? = nil) {
        self.session = session ?? {
            let configuration = TestRunGuard.guarded(.ephemeral)
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 15
            return URLSession(configuration: configuration)
        }()
    }

    func image(for url: URL) async -> NSImage? {
        guard Self.allowed(url), !failed.contains(url) else { return nil }
        if let image = cache[url] { return image }
        let task = loading[url] ?? Task { [session] in await Self.fetch(url, session: session) }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache[url] = image } else { failed.insert(url) }
        return image
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request, delegate: LogoRedirects()),
              let http = response as? HTTPURLResponse, http.statusCode == 200, http.url.map(allowed) ?? false,
              (http.mimeType ?? "").hasPrefix("image/"), !data.isEmpty, data.count <= byteLimit else { return nil }
        return await MainActor.run { NSImage(data: data) }
    }
}

/// A redirect may only stay on the allowed logo host.
private final class LogoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(AppLogoLoader.allowed) == true ? request : nil)
    }
}

private struct AppLogoLoaderKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: (any AppLogoLoading)? = nil }
extension EnvironmentValues {
    var appLogoLoader: (any AppLogoLoading)? {
        get { self[AppLogoLoaderKey.self] }
        set { self[AppLogoLoaderKey.self] = newValue }
    }
}

/// P48: an app's logo, or its first letter on a tinted tile until (or unless) the logo loads.
struct AppLogoView: View {
    @Environment(\.appLogoLoader) private var loader
    let slug: String; let name: String; let logo: URL?
    var size: CGFloat = 32
    @State private var image: NSImage?

    init(slug: String, name: String, logo: URL?, size: CGFloat = 32) { self.slug = slug; self.name = name; self.logo = logo; self.size = size }
    init(_ toolkit: ComposioToolkit, size: CGFloat = 32) { self.init(slug: toolkit.id, name: toolkit.name, logo: toolkit.logo, size: size) }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(size * 0.14) }
            else { Text(String(name.first ?? "?").uppercased()).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size)
        .background(image == nil ? Self.tint(slug) : Color.white, in: RoundedRectangle(cornerRadius: size * 0.24))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(AppColor.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: logo) {
            image = nil
            guard let logo else { return }
            image = await (loader ?? AppLogoLoader.shared).image(for: logo)
        }
    }

    /// A stable color per app, so a letter tile looks the same every time.
    static func tint(_ slug: String) -> Color {
        let hues: [Double] = [0.58, 0.02, 0.33, 0.75, 0.10, 0.48, 0.88, 0.66]
        return Color(hue: hues[slug.utf8.reduce(0) { ($0 &+ Int($1)) } % hues.count], saturation: 0.55, brightness: 0.72)
    }
}
