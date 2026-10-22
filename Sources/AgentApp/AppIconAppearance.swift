import AppKit

/// P38, changed 2026-10-22 (Konrad: "make light version icon default"): the Dock icon has its own preference, Light (the
/// default, also for everyone who never picked one) or Dark, under Settings → Appearance → App icon. The theme no longer
/// moves it. The bundle's light `AppIcon.icns` stays the Finder icon; the running app swaps in
/// `ThemeIcons/SwarmHub-dark|light.png` at launch and when the preference changes.
@MainActor final class AppIconAppearance: NSObject, NSApplicationDelegate {
    static let preferenceKey = "appIcon"
    static let defaultPreference = "Light"

    private let defaults: UserDefaults
    private let setIcon: @MainActor (NSImage) -> Void
    private var images: [Bool: NSImage] = [:]
    private(set) var appliedDark: Bool?

    override convenience init() {
        self.init(defaults: .standard) { NSApp.applicationIconImage = $0 }
    }

    init(defaults: UserDefaults, setIcon: @escaping @MainActor (NSImage) -> Void) {
        self.defaults = defaults
        self.setIcon = setIcon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if QAMode.enabled || UIAcceptanceMode.requested { return }
        #endif
        start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    /// Sets the icon now and again whenever the defaults change (the Settings picker writes them).
    func start() {
        refreshIcon()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    @objc nonisolated private func preferencesChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refreshIcon() }
    }

    /// Dark only for "Dark"; Light for "Light", no choice yet or anything unknown. The theme plays no part.
    static func usesDarkIcon(preference: String?) -> Bool {
        preference == "Dark"
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

    func refreshIcon() {
        let dark = Self.usesDarkIcon(preference: defaults.string(forKey: Self.preferenceKey))
        guard appliedDark != dark, let image = image(dark: dark) else { return }
        setIcon(image)
        appliedDark = dark
    }

    private func image(dark: Bool) -> NSImage? {
        if let cached = images[dark] { return cached }
        guard let image = Self.imageURLs(dark: dark).lazy.compactMap(NSImage.init(contentsOf:)).first else { return nil }
        images[dark] = image
        return image
    }
}
