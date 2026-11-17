import CryptoKit
import Foundation
import Testing

// P23: the committed iconset becomes Contents/Resources/AppIcon.icns in the packaged bundle. The icon is "Crew"
// (Konrad 2026-11-17), drawn by scripts/render-app-icon.py; macOS 26 and later draw it from AppIcon.icon instead.

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

@Test func theDrawingsOfEverySizeAreCommittedAsVectors() {
    let icons = repoRoot.appending(path: "Resources/AppIcon")
    for look in ["light", "dark"] {
        for size in ["", "-32", "-16"] {
            #expect(FileManager.default.fileExists(atPath: icons.appending(path: "SwarmHub-icon-\(look)\(size).svg").path), "missing the \(look)\(size) drawing")
        }
    }
    #expect(FileManager.default.fileExists(atPath: repoRoot.appending(path: "scripts/render-app-icon.py").path))
}

// The Icon Composer icon ships as Assets.car. actool writes an icns of its own beside it, so the iconset's icns comes after.
@Test func packageScriptCompilesTheIconComposerIcon() throws {
    let script = try String(contentsOf: repoRoot.appending(path: "scripts/package-release.sh"), encoding: .utf8)
    let actool = try #require(script.range(of: "xcrun actool \"$ROOT_DIR/Resources/AppIcon/AppIcon.icon\" --compile \"$APP_DIR/Contents/Resources\" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon"))
    let icns = try #require(script.range(of: "iconutil -c icns \"$ROOT_DIR/Resources/AppIcon/AppIcon.iconset\""))
    #expect(actool.upperBound < icns.lowerBound, "the iconset's icns, with its own small drawings, must replace actool's")
    #expect(script.contains("if [[ ! -s \"$APP_DIR/Contents/Resources/Assets.car\" ]]; then"))
}

// Three faces, the front one first, each a face and its eyes; the tile and every layer say what they are in the dark style.
@Test func theIconComposerIconHasItsLayersAndADarkVariant() throws {
    let icon = repoRoot.appending(path: "Resources/AppIcon/AppIcon.icon")
    let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: icon.appending(path: "icon.json"))) as? [String: Any])
    #expect(document["fill"] == nil, "a plain fill beside the list wins, and macOS then picks the dark tile itself")
    let tile = try #require(document["fill-specializations"] as? [[String: Any]])
    #expect(tile.first?["appearance"] == nil && tile.contains { $0["appearance"] as? String == "dark" })
    let groups = try #require(document["groups"] as? [[String: Any]])
    var images: [String] = []
    for group in groups {
        for layer in try #require(group["layers"] as? [[String: Any]]) {
            let image = try #require(layer["image-name"] as? String)
            images.append(image)
            #expect(FileManager.default.fileExists(atPath: icon.appending(path: "Assets/\(image)").path), "missing layer \(image)")
            let fill = try #require(layer["fill-specializations"] as? [[String: Any]])
            #expect(fill.first?["appearance"] == nil && fill.contains { $0["appearance"] as? String == "dark" }, "\(image) has no dark colour")
        }
    }
    #expect(images == ["front-eyes.svg", "front.svg", "right-eyes.svg", "right.svg", "left-eyes.svg", "left.svg"])
}

// 64 px and larger and the two images the app sets itself are macOS's own pictures of that icon (Renditions/); the
// stamp beside them names the icon they were made from, so a changed drawing with stale pictures fails here.
@Test func theRenditionsAreOfTheCommittedIcon() throws {
    let icons = repoRoot.appending(path: "Resources/AppIcon"), icon = icons.appending(path: "AppIcon.icon")
    var isDirectory: ObjCBool = false
    let files = try FileManager.default.subpathsOfDirectory(atPath: icon.path).filter { path in
        FileManager.default.fileExists(atPath: icon.appending(path: path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && !(path as NSString).lastPathComponent.hasPrefix(".")
    }.sorted()
    var hash = SHA256()
    for file in files {
        hash.update(data: Data(file.utf8) + [0])
        hash.update(data: try Data(contentsOf: icon.appending(path: file)))
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let stamp = try String(contentsOf: icons.appending(path: "Renditions/source.sha256"), encoding: .utf8)
    #expect(stamp == "\(digest) generation 26\n", "run scripts/render-app-icon.py --renditions on a Mac, then the script again")
    for name in ["default.png", "dark.png"] {
        #expect(FileManager.default.fileExists(atPath: icons.appending(path: "Renditions/\(name)").path))
    }
}
