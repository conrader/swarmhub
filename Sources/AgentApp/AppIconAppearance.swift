import AppKit

/// P38: the Dock icon follows the app's Light/Dark/System preference. The bundle's light `AppIcon.icns` stays the Finder
/// fallback; the running app swaps in `ThemeIcons/SwarmHub-dark|light.png` at launch, when the preference changes and,
/// on System, when macOS switches appearance (also with no window open).
@MainActor final class AppIconAppearance: NSObject, NSApplicationDelegate {
    private var systemAppearance: NSKeyValueObservation?
    private var images: [Bool: NSImage] = [:]
    private var appliedDark: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        systemAppearance = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshIcon() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemAppearance?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func preferencesChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refreshIcon() }
    }

    /// Dark for "Dark", light for "Light", else the system's appearance.
    static func usesDarkIcon(preference: String, systemDark: Bool) -> Bool {
        switch AppTheme.colorScheme(for: preference) {
        case .dark: true
        case .light: false
        default: systemDark
        }
    }

    /// The installed app's Resources, the SwiftPM bundle or `swiftc` folder beside the binary, or the checkout (tests).
    /// P38 E: the dark `.icns` (`AppIcon-dark.icns` in the app, `SwarmHub-dark.icns` in the checkout) follows the PNGs.
    static func imageURLs(dark: Bool) -> [URL] {
        let name = "ThemeIcons/SwarmHub-\(dark ? "dark" : "light").png"
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/AppIcon")
        let icns = dark ? [Bundle.main.resourceURL?.appending(path: "AppIcon-dark.icns"), executable.appending(path: "AgentApp.resources/AppIcon-dark.icns"),
                           checkout.appending(path: "SwarmHub-dark.icns")] : []
        return ([
            Bundle.main.resourceURL?.appending(path: name),
            executable.appending(path: "AgentApp_AgentApp.bundle/\(name)"),
            executable.appending(path: "AgentApp_AgentApp.bundle/Contents/Resources/\(name)"),
            executable.appending(path: "AgentApp.resources/\(name)"),
            checkout.appending(path: name)
        ] + icns).compactMap { $0 }
    }

    private func refreshIcon() {
        let preference = ProcessInfo.processInfo.environment["AGENTAPP_APPEARANCE"]
            ?? UserDefaults.standard.string(forKey: "appearance") ?? AppTheme.defaultPreference
        let dark = Self.usesDarkIcon(preference: preference, systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        guard appliedDark != dark, let image = image(dark: dark) else { return }
        NSApp.applicationIconImage = image
        appliedDark = dark
    }

    private func image(dark: Bool) -> NSImage? {
        if let cached = images[dark] { return cached }
        guard let image = Self.imageURLs(dark: dark).lazy.compactMap(NSImage.init(contentsOf:)).first else { return nil }
        images[dark] = image
        return image
    }
}
