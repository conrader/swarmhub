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
