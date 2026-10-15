import Foundation
import Testing

// P23: the committed Swarm iconset becomes Contents/Resources/AppIcon.icns in the packaged bundle.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func infoPlistReferencesTheAppIcon() throws {
    let plist = try #require(NSDictionary(contentsOf: repoRoot.appending(path: "Resources/Info.plist")) as? [String: Any])
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    #expect(plist["CFBundleIconName"] as? String == "AppIcon")
}

@Test func iconsetHasEverySizeIconutilNeeds() {
    let iconset = repoRoot.appending(path: "Resources/AppIcon/AppIcon.iconset")
    for size in [16, 32, 128, 256, 512] {
        for name in ["icon_\(size)x\(size).png", "icon_\(size)x\(size)@2x.png"] {
            #expect(FileManager.default.fileExists(atPath: iconset.appending(path: name).path), "missing \(name)")
        }
    }
}

@Test func packageScriptBuildsAndChecksTheIcns() throws {
    let script = try String(contentsOf: repoRoot.appending(path: "scripts/package-release.sh"), encoding: .utf8)
    #expect(script.contains("iconutil -c icns \"$ROOT_DIR/Resources/AppIcon/AppIcon.iconset\" -o \"$APP_DIR/Contents/Resources/AppIcon.icns\""))
    // The script fails when the signed bundle lacks the icon.
    #expect(script.contains("if [[ ! -s \"$APP_DIR/Contents/Resources/AppIcon.icns\" ]]; then"))
    // P38 E: the dark icon ships as an icns too and is checked like the light one.
    #expect(script.contains("iconutil -c icns \"$ROOT_DIR/Resources/AppIcon/AppIcon-dark.iconset\" -o \"$APP_DIR/Contents/Resources/AppIcon-dark.icns\""))
    #expect(script.contains("for ICON in AppIcon-dark.icns ThemeIcons/SwarmHub-light.png ThemeIcons/SwarmHub-dark.png; do"))
}

