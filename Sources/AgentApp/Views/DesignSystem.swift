import AppKit
import SwiftUI

struct AvatarImage: View {
    let name: BotAvatarName
    var body: some View {
#if SWIFT_PACKAGE
        Image(name.rawValue, bundle: .module).resizable()
#else
        Image(nsImage: AvatarAssets.image(named: name.rawValue)).resizable()
#endif
    }
}

#if !SWIFT_PACKAGE
private enum AvatarAssets {
    static func image(named name: String) -> NSImage {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            executable.appending(path: "AgentApp.resources/Avatars/\(name).png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Avatars/\(name).png")
        ]
        return candidates.lazy.compactMap(NSImage.init(contentsOf:)).first ?? NSImage(size: NSSize(width: 28, height: 28))
    }
}
#endif

struct BotAvatar: View {
    let bot: Bot; var size: CGFloat = 38
    var body: some View {
        AvatarImage(name: bot.avatarName)
            .scaledToFill().frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct NeutralPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: .textBackgroundColor)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension Notification.Name {
    static let toggleInfo = Notification.Name("AgentApp.toggleInfo")
    static let newBot = Notification.Name("AgentApp.newBot")
}
