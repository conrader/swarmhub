import AppKit
import Testing
@testable import AgentApp

/// The images the Dock would have shown, in order.
@MainActor private final class AppliedIcons { var images: [NSImage] = [] }

// Konrad 2026-10-22: "make light version icon default", with a setting to pick the dark icon; the theme no longer moves it.
@MainActor @Test func dockIconIsLightUnlessDarkIsPicked() {
    #expect(AppIconAppearance.usesDarkIcon(preference: "Dark"))
    #expect(!AppIconAppearance.usesDarkIcon(preference: "Light"))
    #expect(!AppIconAppearance.usesDarkIcon(preference: nil), "no choice yet (every existing install) is Light")
    #expect(!AppIconAppearance.usesDarkIcon(preference: "System") && !AppIconAppearance.usesDarkIcon(preference: "dark"), "unknown words are Light")
    #expect(AppIconAppearance.preferenceKey == "appIcon" && AppIconAppearance.defaultPreference == "Light")
    #expect(AppIconAppearance.preferenceKey != "appearance", "a key of its own, apart from the theme")
}

@MainActor @Test func theIconPreferenceIsIndependentOfTheTheme() {
    let defaults = isolatedDefaults()
    let applied = AppliedIcons()
    let icon = AppIconAppearance(defaults: defaults) { applied.images.append($0) }
    for theme in ["Dark", "Light", "System"] {
        defaults.set(theme, forKey: "appearance")
        icon.refreshIcon()
        #expect(icon.appliedDark == false, "theme \(theme) keeps the light icon")
    }
    #expect(applied.images.count == 1, "the theme changes never swap the icon again")
    defaults.set("Dark", forKey: AppIconAppearance.preferenceKey)
    for theme in ["Dark", "Light", "System"] {
        defaults.set(theme, forKey: "appearance")
        icon.refreshIcon()
        #expect(icon.appliedDark == true, "theme \(theme) keeps the dark icon")
    }
    #expect(applied.images.count == 2)
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
    let theme = try #require(pane.range(of: "Picker(SimpleCopy.theme")), appIcon = try #require(pane.range(of: "Picker(SimpleCopy.appIcon"))
    let accent = try #require(pane.range(of: "Picker(SimpleCopy.accent"))
    #expect(theme.upperBound < appIcon.lowerBound && appIcon.upperBound < accent.lowerBound, "Theme, App icon, Accent")
    #expect(pane.contains(#"Picker(SimpleCopy.appIcon, selection: $appIcon) { Text(SimpleCopy.light).tag("Light"); Text(SimpleCopy.dark).tag("Dark") }.pickerStyle(.segmented)"#))
    #expect(SimpleCopy.appIcon == "App icon" && SimpleCopy.all.contains(SimpleCopy.appIcon))
    #expect(SettingsLayout.home(of: "appearance.appIcon") == .simple)
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
    #expect(!AppIconAppearance.imageURLs(dark: false).contains { $0.pathExtension == "icns" }, "the light fallback stays the bundle's AppIcon.icns")
}
