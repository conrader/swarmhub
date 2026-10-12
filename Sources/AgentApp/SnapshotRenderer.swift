import AppKit
import SwiftUI

@MainActor enum SnapshotRenderer {
    static func capture(store: AppStore, to path: String) {
        let size = NSSize(width: 1120, height: 760)
        let preference = UserDefaults.standard.string(forKey: "appearance") ?? AppTheme.defaultPreference
        let scheme = AppTheme.colorScheme(for: preference) ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ColorScheme.dark : .light)
        let view = NSHostingView(rootView: ContentView().environmentObject(store).environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
