import AppKit
import Testing
@testable import AgentApp

@MainActor @Test func dockIconFollowsTheAppearancePreference() {
    #expect(AppIconAppearance.usesDarkIcon(preference: "Dark", systemDark: false))
    #expect(!AppIconAppearance.usesDarkIcon(preference: "Light", systemDark: true))
    #expect(AppIconAppearance.usesDarkIcon(preference: "System", systemDark: true))
    #expect(!AppIconAppearance.usesDarkIcon(preference: "System", systemDark: false))
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
