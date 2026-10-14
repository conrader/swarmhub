import AppKit
import SwiftUI

@MainActor enum SnapshotRenderer {
    static func capture(store: AppStore, to path: String) {
        let size = NSSize(width: 1120, height: 760)
        let preference = UserDefaults.standard.string(forKey: "appearance") ?? AppTheme.defaultPreference
        let scheme = AppTheme.colorScheme(for: preference) ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ColorScheme.dark : .light)
        var done = false
        Task { @MainActor in
            if let data = await contentPNG(store: store, size: size, scale: 1, scheme: scheme) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
    }

    /// The full window content. macOS glass containers need their actual pane content redrawn offscreen.
    static func contentPNG(store: AppStore, size: NSSize, scale: CGFloat = 2, scheme: ColorScheme = .dark, historyExpanded: Bool = false) async -> Data? {
        await png(ContentView().environmentObject(store).defaultAppStorage(store.defaults).environment(\.grokHistoryExpanded, historyExpanded), size: size, scale: scale, scheme: scheme) { region in
            if region.midX > size.width / 2 {
                if let group = store.selectedGroup {
                    return AnyView(GroupInfoPanel(group: group).environmentObject(store).defaultAppStorage(store.defaults))
                }
                if let bot = store.selectedBot {
                    return AnyView(InfoPanel(bot: bot).environmentObject(store).defaultAppStorage(store.defaults))
                }
            }
            return AnyView(SidebarView(selection: .constant(store.selectedBot)).environmentObject(store).defaultAppStorage(store.defaults))
        }
    }

    /// Renders a view offscreen to PNG data at `scale` pixels per point. Uses an `NSHostingView` in a
    /// window that is never ordered on screen: `ImageRenderer` draws AppKit-backed views
    /// (NavigationSplitView, ScrollView, TextField) as placeholders, so it cannot capture the real UI.
    static func png<V: View>(_ view: V, size: NSSize, scale: CGFloat = 2, scheme: ColorScheme = .dark, glassContent: ((NSRect) -> AnyView)? = nil) async -> Data? {
        await render(view, size: size, scale: scale, scheme: scheme, glassContent: glassContent)?.representation(using: .png, properties: [:])
    }

    private static func render<V: View>(_ view: V, size: NSSize, scale: CGFloat, scheme: ColorScheme, glassContent: ((NSRect) -> AnyView)?) async -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = appearance; window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // Let SwiftUI settle (lazy stacks, archive loads) before drawing, without holding the main actor.
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(100)) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        (appearance ?? host.effectiveAppearance).performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        await redrawGlass(in: host, onto: bitmap, scale: scale, scheme: scheme, appearance: appearance, glassContent: glassContent)
        window.contentView = nil; window.close()
        return bitmap
    }

    /// `cacheDisplay` cannot reproduce macOS glass. Pass each region's position to the pane renderer
    /// so nested split views keep their own content instead of receiving another copy of the sidebar.
    private static func redrawGlass(in host: NSView, onto bitmap: NSBitmapImageRep, scale: CGFloat, scheme: ColorScheme, appearance: NSAppearance?, glassContent: ((NSRect) -> AnyView)?) async {
        let glasses = descendants(of: host).filter { String(describing: type(of: $0)).contains("GlassEffectView") }
        guard !glasses.isEmpty else { return }
        func target(_ view: NSView) -> NSRect {
            let rect = view.convert(view.bounds, to: host)
            return host.isFlipped ? NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        var layers: [(NSRect, NSBitmapImageRep)] = []
        for glass in glasses {
            if let glassContent {
                // Glass backdrops can extend past the window; keep the redrawn pane inside the capture.
                let region = target(glass.superview ?? glass).intersection(host.bounds)
                guard !region.isEmpty else { continue }
                if let rep = await render(glassContent(region), size: region.size, scale: scale, scheme: scheme, glassContent: nil) { layers.append((region, rep)) }
                continue
            }
            // Without an override, draw the app's hosting views; the glass's own `_NSCoreHostingView` is the blank sheet.
            let hosted = descendants(of: glass).filter { String(describing: type(of: $0)).hasPrefix("NSHostingView<") && !$0.isHidden }
            for content in hosted where !hosted.contains(where: { $0 !== content && content.isDescendant(of: $0) }) {
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                content.cacheDisplay(in: content.bounds, to: rep)
                layers.append((target(content), rep))
            }
        }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        (appearance ?? host.effectiveAppearance).performAsCurrentDrawingAppearance {
            for glass in glasses { NSColor(AppColor.sidebar).setFill(); target(glass.superview ?? glass).fill() }
            for (rect, rep) in layers { rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil) }
        }
    }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
}
