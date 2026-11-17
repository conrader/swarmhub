import AppKit
import SwiftUI

/// The one place that decides which of the two app icons is drawn: the Dock icon, the About panel and the setup wizard's
/// mark all ask here. Konrad 2026-11-17: "The dark icon should be only used in specific environments, but default should
/// be the light icon." So the icon is Light everywhere, for everyone who never picked one too; it is Dark only where
/// Settings → Appearance → App icon says Dark and the app is shown dark (Theme Dark, or Theme System on a dark Mac).
///
/// Why the app draws its own icon instead of leaving it to the bundle: macOS 26 draws a bundle's icon in the icon style
/// of the Mac (System Settings → Appearance), so on a Mac with dark icons the standard About panel and the Dock during
/// launch show the dark drawing of `AppIcon.icon` whatever is picked here (and, for a bundle without that icon, a dark
/// tile macOS makes up). The app can replace it only once it runs, so it sets its icon first thing at launch and hands
/// the same image to the About panel. The light image is what macOS draws from `AppIcon.icon` in the Default style.
@MainActor final class AppIconAppearance: NSObject, NSApplicationDelegate {
    static let preferenceKey = "appIcon"
    static let defaultPreference = "Light"
    static let themeKey = "appearance"

    private static var images: [Bool: NSImage] = [:]

    private let defaults: UserDefaults
    private let systemIsDark: @MainActor () -> Bool
    private let setIcon: @MainActor (NSImage) -> Void
    private var systemAppearance: NSKeyValueObservation?
    private(set) var appliedDark: Bool?

    override convenience init() {
        self.init(defaults: .standard, systemIsDark: { AppIconAppearance.systemIsDark }) { NSApplication.shared.applicationIconImage = $0 }
    }

    init(defaults: UserDefaults, systemIsDark: @escaping @MainActor () -> Bool = { false }, setIcon: @escaping @MainActor (NSImage) -> Void) {
        self.defaults = defaults
        self.systemIsDark = systemIsDark
        self.setIcon = setIcon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
        systemAppearance = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshIcon() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        systemAppearance = nil
    }

    /// Sets the icon now and again whenever the defaults change (the Settings pickers write them).
    func start() {
        refreshIcon()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc nonisolated private func preferencesChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refreshIcon() }
    }

    // MARK: The rule

    /// Dark only when "Dark" was picked and the app is shown dark. No choice yet, "Light" or an unknown word is Light
    /// in every surrounding; a picked "Dark" is still Light while the app is light.
    static func usesDarkIcon(preference: String?, theme: String?, systemIsDark: Bool) -> Bool {
        guard preference == "Dark" else { return false }
        switch AppTheme.colorScheme(for: theme ?? AppTheme.defaultPreference) {
        case .dark?: return true
        case .light?: return false
        default: return systemIsDark
        }
    }

    /// The rule with what is saved now.
    static func usesDarkIcon(defaults: UserDefaults = .standard, systemIsDark: Bool) -> Bool {
        usesDarkIcon(preference: defaults.string(forKey: preferenceKey), theme: defaults.string(forKey: themeKey), systemIsDark: systemIsDark)
    }

    /// Whether macOS itself is dark (the app sets no appearance of its own on `NSApplication`).
    static var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The icon to draw now, for a panel or a view; nil only when no icon file can be read.
    static func currentImage(defaults: UserDefaults = .standard) -> NSImage? {
        image(dark: usesDarkIcon(defaults: defaults, systemIsDark: systemIsDark))
    }

    // MARK: Where it is applied

    /// Called first thing in the app's `init`: the Dock shows the bundle's icon (on a Mac with dark icons, the system's
    /// darkened drawing of it) until the process sets its own, so it is set before the store loads.
    static func applyAtLaunch() {
        guard let image = currentImage() else { return }
        NSApplication.shared.applicationIconImage = image
    }

    /// App menu → About: the standard panel, with this icon instead of the bundle's (see the note on the type).
    static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let image = currentImage() { options[.applicationIcon] = image }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    func refreshIcon() {
        let dark = Self.usesDarkIcon(defaults: defaults, systemIsDark: systemIsDark())
        guard appliedDark != dark, let image = Self.image(dark: dark) else { return }
        setIcon(image)
        appliedDark = dark
    }

    // MARK: The two images

    /// The installed app's Resources, the SwiftPM bundle or `swiftc` folder beside the binary, or the checkout (tests).
    /// The `.icns` files follow the PNGs, for when a PNG cannot be read: `AppIcon.icns` (light) and `AppIcon-dark.icns`
    /// in the app, the iconset's largest image and `SwarmHub-dark.icns` in the checkout.
    static func imageURLs(dark: Bool) -> [URL] {
        let name = "ThemeIcons/SwarmHub-\(dark ? "dark" : "light").png"
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/AppIcon")
        let fallbacks = dark
            ? [Bundle.main.resourceURL?.appending(path: "AppIcon-dark.icns"), executable.appending(path: "AgentApp.resources/AppIcon-dark.icns"),
               checkout.appending(path: "SwarmHub-dark.icns")]
            : [Bundle.main.resourceURL?.appending(path: "AppIcon.icns"), checkout.appending(path: "AppIcon.iconset/icon_512x512@2x.png")]
        return ([
            Bundle.main.resourceURL?.appending(path: name),
            executable.appending(path: "AgentApp_AgentApp.bundle/\(name)"),
            executable.appending(path: "AgentApp_AgentApp.bundle/Contents/Resources/\(name)"),
            executable.appending(path: "AgentApp.resources/\(name)"),
            checkout.appending(path: name)
        ] + fallbacks).compactMap { $0 }
    }

    /// The light or the dark image, read once.
    static func image(dark: Bool) -> NSImage? {
        if let cached = images[dark] { return cached }
        guard let image = imageURLs(dark: dark).lazy.compactMap(NSImage.init(contentsOf:)).first else { return nil }
        images[dark] = image
        return image
    }
}

/// The app's icon inside the app (the setup wizard's first page): the same rule as the Dock icon, in the colours the
/// view is shown in. `fallback` is drawn where no icon file can be read.
struct AppIconMark<Fallback: View>: View {
    var size: CGFloat
    @ViewBuilder var fallback: () -> Fallback
    @AppStorage(AppIconAppearance.preferenceKey) private var appIcon = AppIconAppearance.defaultPreference
    @AppStorage(AppIconAppearance.themeKey) private var theme = AppTheme.defaultPreference
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A view under Theme System has the Mac's own colours, so its colour scheme is the system's.
        if let image = AppIconAppearance.image(dark: AppIconAppearance.usesDarkIcon(preference: appIcon, theme: theme, systemIsDark: colorScheme == .dark)) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            fallback()
        }
    }
}
