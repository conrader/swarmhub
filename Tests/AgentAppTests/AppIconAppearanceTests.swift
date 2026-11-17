import AppKit
import Testing
@testable import AgentApp

/// The images the Dock would have shown, in order.
@MainActor private final class AppliedIcons { var images: [NSImage] = [] }
/// Whether the Mac the test pretends to run on is dark.
@MainActor private final class PretendMac { var isDark: Bool; init(isDark: Bool) { self.isDark = isDark } }

// Konrad 2026-10-22: "make light version icon default". Konrad 2026-11-17: "The dark icon should be only used in specific
// environments, but default should be the light icon." Light everywhere unless Dark is picked and the app is shown dark.
@MainActor @Test func theIconIsLightUnlessDarkIsPickedAndTheAppIsShownDark() {
    for theme in ["Dark", "Light", "System", nil] as [String?] {
        for systemIsDark in [true, false] {
            for preference in ["Light", nil, "System", "dark"] as [String?] {
                #expect(!AppIconAppearance.usesDarkIcon(preference: preference, theme: theme, systemIsDark: systemIsDark),
                        "preference \(preference ?? "none"), theme \(theme ?? "none"), dark Mac \(systemIsDark): Light")
            }
        }
    }
    for systemIsDark in [true, false] {
        #expect(AppIconAppearance.usesDarkIcon(preference: "Dark", theme: "Dark", systemIsDark: systemIsDark))
        #expect(AppIconAppearance.usesDarkIcon(preference: "Dark", theme: nil, systemIsDark: systemIsDark), "no theme saved is the default theme, Dark")
        #expect(!AppIconAppearance.usesDarkIcon(preference: "Dark", theme: "Light", systemIsDark: systemIsDark), "a light app keeps the light icon")
    }
    #expect(AppIconAppearance.usesDarkIcon(preference: "Dark", theme: "System", systemIsDark: true))
    #expect(!AppIconAppearance.usesDarkIcon(preference: "Dark", theme: "System", systemIsDark: false))
    #expect(AppIconAppearance.preferenceKey == "appIcon" && AppIconAppearance.defaultPreference == "Light")
    #expect(AppIconAppearance.themeKey == "appearance" && AppTheme.defaultPreference == "Dark")
}

@MainActor @Test func withNoIconPickedNoThemeOrMacAppearanceMakesTheIconDark() {
    let defaults = isolatedDefaults()
    let applied = AppliedIcons()
    let mac = PretendMac(isDark: true)
    let icon = AppIconAppearance(defaults: defaults, systemIsDark: { mac.isDark }) { applied.images.append($0) }
    for theme in ["Dark", "Light", "System"] {
        for dark in [true, false] {
            defaults.set(theme, forKey: AppIconAppearance.themeKey); mac.isDark = dark
            icon.refreshIcon()
            #expect(icon.appliedDark == false, "theme \(theme), dark Mac \(dark) keeps the light icon")
        }
    }
    #expect(applied.images.count == 1, "the icon is set once and never swapped")
}

@MainActor @Test func aPickedDarkIconFollowsTheThemeAndTheMac() {
    let defaults = isolatedDefaults()
    let applied = AppliedIcons()
    let mac = PretendMac(isDark: false)
    let icon = AppIconAppearance(defaults: defaults, systemIsDark: { mac.isDark }) { applied.images.append($0) }
    defaults.set("Dark", forKey: AppIconAppearance.preferenceKey)
    icon.refreshIcon()
    #expect(icon.appliedDark == true, "the default theme is Dark")
    defaults.set("Light", forKey: AppIconAppearance.themeKey); icon.refreshIcon()
    #expect(icon.appliedDark == false, "a light app shows the light icon")
    defaults.set("System", forKey: AppIconAppearance.themeKey); icon.refreshIcon()
    #expect(icon.appliedDark == false, "Theme System on a light Mac")
    mac.isDark = true; icon.refreshIcon()
    #expect(icon.appliedDark == true, "Theme System once the Mac turns dark")
    mac.isDark = false; icon.refreshIcon()
    #expect(icon.appliedDark == false)
    #expect(applied.images.count == 4, "one swap per change, none in between")
    #expect(AppIconAppearance.usesDarkIcon(defaults: defaults, systemIsDark: true) && !AppIconAppearance.usesDarkIcon(defaults: defaults, systemIsDark: false))
}

// The Dock icon, the About panel and the wizard's mark take the icon from AppIconAppearance, and nothing else picks one.
@MainActor @Test func everyPlaceTheIconIsDrawnAsksTheSameRule() throws {
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = repoRoot.appending(path: "Sources/AgentApp")
    func read(_ path: String) throws -> String { try String(contentsOf: sources.appending(path: path), encoding: .utf8) }
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    for file in files where file.lastPathComponent != "AppIconAppearance.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("applicationIconImage") && !text.contains("applicationIconName") && !text.contains("ThemeIcons/"),
                "\(file.lastPathComponent) reads the app icon on its own")
        #expect(!text.contains("orderFrontStandardAboutPanel"), "\(file.lastPathComponent) opens About without the picked icon")
    }
    let commands = try read("AppCommands.swift")
    #expect(commands.contains("CommandGroup(replacing: .appInfo)") && commands.contains("AppIconAppearance.showAboutPanel()"))
    #expect(!commands.contains("CommandGroup(after: .appInfo)"), "the standard About item would show the bundle's icon")
    let wizard = try read("Setup/SetupHerdrSteps.swift")
    #expect(wizard.contains("AppIconMark(size: size)"))
    // The icon is set before the store loads, so the Dock does not show the bundle's icon for the whole launch.
    let app = try read("AgentApp.swift")
    let apply = try #require(app.range(of: "AppIconAppearance.applyAtLaunch()")), store = try #require(app.range(of: "AppStore("))
    #expect(apply.upperBound < store.lowerBound)
    #expect(app.contains("@NSApplicationDelegateAdaptor(AppIconAppearance.self)"))
    let icon = try read("AppIconAppearance.swift")
    #expect(icon.contains("options[.applicationIcon] = image"))
    #expect(icon.components(separatedBy: "preference == \"Dark\"").count == 2, "one rule")
}

@MainActor @Test func pickingAnIconInSettingsSwapsTheDockIcon() async throws {
    let defaults = isolatedDefaults()
    let applied = AppliedIcons()
    let icon = AppIconAppearance(defaults: defaults) { applied.images.append($0) }
    icon.start()
    #expect(icon.appliedDark == false && applied.images.count == 1, "launch sets the light icon")
    let light = try #require(applied.images.last?.tiffRepresentation)
    defaults.set("Dark", forKey: AppIconAppearance.preferenceKey)
    try await waitUntil { icon.appliedDark == true }
    #expect(applied.images.count == 2 && applied.images.last?.tiffRepresentation != light, "the dark image replaced the light one")
    defaults.set("Light", forKey: AppIconAppearance.preferenceKey)
    try await waitUntil { icon.appliedDark == false }
    #expect(applied.images.count == 3)
    icon.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
}

@MainActor @Test func settingsOffersTheAppIconBesideTheTheme() throws {
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pane = try String(contentsOf: repoRoot.appending(path: "Sources/AgentApp/Views/SettingsSimplePane.swift"), encoding: .utf8)
    #expect(pane.contains("@AppStorage(AppIconAppearance.preferenceKey) private var appIcon = AppIconAppearance.defaultPreference"))
    let theme = try #require(pane.range(of: "ThemeTile(value: value")), appIcon = try #require(pane.range(of: "SegmentedChoice(title: SimpleCopy.appIcon"))
    let accent = try #require(pane.range(of: "SettingBlock(title: SimpleCopy.accent"))
    #expect(theme.upperBound < appIcon.lowerBound && appIcon.upperBound < accent.lowerBound, "Theme, App icon, Accent")
    // The app's own two-part choice, whose chosen half is filled with the accent and ticked (`SegmentedChoice`).
    #expect(pane.contains(#"SegmentedChoice(title: SimpleCopy.appIcon, options: [("Light", SimpleCopy.light), ("Dark", SimpleCopy.dark)], selection: $appIcon)"#))
    #expect(SimpleCopy.appIcon == "App icon" && SimpleCopy.all.contains(SimpleCopy.appIcon))
    #expect(SettingsLayout.home(of: "appearance.appIcon") == .general)
}

@MainActor @Test func bothThemeIconsAreBundledAndDiffer() throws {
    let light = try #require(AppIconAppearance.imageURLs(dark: false).first { FileManager.default.fileExists(atPath: $0.path) })
    let dark = try #require(AppIconAppearance.imageURLs(dark: true).first { FileManager.default.fileExists(atPath: $0.path) })
    let lightData = try Data(contentsOf: light), darkData = try Data(contentsOf: dark)
    #expect(lightData != darkData)
    for data in [lightData, darkData] {
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1024 && image.pixelsHigh == 1024)
    }
}

@MainActor @Test func theDarkIcnsIsAFallbackForTheDarkDockIcon() throws {
    let icns = try #require(AppIconAppearance.imageURLs(dark: true).first { $0.pathExtension == "icns" && FileManager.default.fileExists(atPath: $0.path) })
    #expect(icns.lastPathComponent == "SwarmHub-dark.icns")
    let image = try #require(NSImage(contentsOf: icns))
    #expect(image.representations.contains { $0.pixelsWide == 1024 })
    #expect(AppIconAppearance.image(dark: true) != nil)
}

// The light icon never falls back to whatever macOS draws for the bundle: it has files of its own to read.
@MainActor @Test func theLightIconHasFallbackFilesToo() throws {
    let urls = AppIconAppearance.imageURLs(dark: false)
    #expect(urls.contains { $0.lastPathComponent == "AppIcon.icns" }, "the installed app's own light icns")
    #expect(!urls.contains { $0.path.contains("dark") })
    let largest = try #require(urls.first { $0.lastPathComponent == "icon_512x512@2x.png" && FileManager.default.fileExists(atPath: $0.path) })
    let first = try #require(urls.first { FileManager.default.fileExists(atPath: $0.path) })
    let largestData = try Data(contentsOf: largest), firstData = try Data(contentsOf: first)
    #expect(largestData == firstData, "the iconset's largest image is the light icon")
    let light = try #require(AppIconAppearance.image(dark: false)), dark = try #require(AppIconAppearance.image(dark: true))
    #expect(light.tiffRepresentation != dark.tiffRepresentation)
}
