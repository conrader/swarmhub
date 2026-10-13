import AppKit
import SwiftUI

enum AppTheme {
    static let defaultPreference = "Dark"

    static func colorScheme(for preference: String) -> ColorScheme? {
        switch preference {
        case "Light": .light
        case "System": nil
        default: .dark
        }
    }
}

enum AppColor {
    static let sidebar = adaptive(light: 0xF2F2F4, dark: 0x0E0E10)
    static let chat = adaptive(light: 0xFFFFFF, dark: 0x141416)
    static let panel = adaptive(light: 0xF8F8FA, dark: 0x19191C)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1D1D20)
    static let raised = adaptive(light: 0xF0F0F3, dark: 0x232327)
    static let separator = adaptive(light: 0xD9D9DE, dark: 0x2C2C30)
    static let selection = adaptive(light: 0xE3E3E7, dark: 0x29292D)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

struct AvatarImage: View {
    let name: BotAvatarName
    var body: some View {
        if name.isFlatFace {
            FlatBotFace(name: name)
        } else {
#if SWIFT_PACKAGE
            Image(name.rawValue, bundle: .module).resizable()
#else
            Image(nsImage: AvatarAssets.image(named: name.rawValue)).resizable()
#endif
        }
    }
}

/// Original vector bot faces. They intentionally use only SwiftUI geometry and
/// system rendering so no third-party artwork, font, or extracted asset is shipped.
struct FlatBotFace: View {
    let name: BotAvatarName
    private var palette: (Color, Color) {
        switch name {
        case .faceCoral: (.init(red: 0.95, green: 0.48, blue: 0.42), .init(red: 0.45, green: 0.16, blue: 0.16))
        case .faceSky: (.init(red: 0.48, green: 0.75, blue: 0.94), .init(red: 0.12, green: 0.27, blue: 0.42))
        case .faceMint: (.init(red: 0.48, green: 0.82, blue: 0.67), .init(red: 0.10, green: 0.34, blue: 0.23))
        case .faceSun: (.init(red: 0.96, green: 0.76, blue: 0.35), .init(red: 0.40, green: 0.25, blue: 0.08))
        case .faceLilac: (.init(red: 0.70, green: 0.60, blue: 0.91), .init(red: 0.27, green: 0.18, blue: 0.42))
        case .faceRose: (.init(red: 0.94, green: 0.62, blue: 0.72), .init(red: 0.43, green: 0.17, blue: 0.28))
        case .faceOcean: (.init(red: 0.33, green: 0.70, blue: 0.72), .init(red: 0.07, green: 0.30, blue: 0.32))
        case .faceLime: (.init(red: 0.70, green: 0.82, blue: 0.43), .init(red: 0.26, green: 0.34, blue: 0.08))
        case .facePeach: (.init(red: 0.96, green: 0.67, blue: 0.48), .init(red: 0.44, green: 0.22, blue: 0.10))
        case .faceBlue: (.init(red: 0.39, green: 0.58, blue: 0.89), .init(red: 0.09, green: 0.20, blue: 0.42))
        case .facePlum: (.init(red: 0.69, green: 0.45, blue: 0.69), .init(red: 0.31, green: 0.12, blue: 0.31))
        default: (.init(red: 0.80, green: 0.71, blue: 0.56), .init(red: 0.32, green: 0.25, blue: 0.16))
        }
    }
    var body: some View {
        Canvas { context, size in
            let inset = size.width * 0.10
            let head = CGRect(x: inset, y: size.height * 0.17, width: size.width - inset * 2, height: size.height * 0.68)
            context.fill(Path(roundedRect: head, cornerRadius: size.width * 0.25), with: .color(palette.0))
            let antenna = Path(CGRect(x: size.width * 0.47, y: size.height * 0.06, width: size.width * 0.06, height: size.height * 0.15))
            context.fill(antenna, with: .color(palette.1.opacity(0.7)))
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.42, y: size.height * 0.03, width: size.width * 0.16, height: size.width * 0.16)), with: .color(palette.0))
            for x in [0.34, 0.62] { context.fill(Path(ellipseIn: CGRect(x: size.width * x, y: size.height * 0.43, width: size.width * 0.075, height: size.width * 0.075)), with: .color(palette.1)) }
            var mouth = Path(); mouth.move(to: CGPoint(x: size.width * 0.43, y: size.height * 0.64)); mouth.addQuadCurve(to: CGPoint(x: size.width * 0.57, y: size.height * 0.64), control: CGPoint(x: size.width * 0.50, y: size.height * 0.72))
            context.stroke(mouth, with: .color(palette.1), lineWidth: max(1.2, size.width * 0.045))
        }.aspectRatio(1, contentMode: .fit)
    }
}

#if !SWIFT_PACKAGE
private enum AvatarAssets {
    static func image(named name: String) -> NSImage {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Avatars/\(name).png"),
            executable.appending(path: "AgentApp.resources/Avatars/\(name).png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Avatars/\(name).png")
        ].compactMap { $0 }
        return candidates.lazy.compactMap(NSImage.init(contentsOf:)).first ?? NSImage(size: NSSize(width: 28, height: 28))
    }
}
#endif

struct BotAvatar: View {
    let bot: Bot; var size: CGFloat = 38
    var body: some View {
        AvatarImage(name: bot.avatarName)
            .scaledToFill().frame(width: size, height: size).clipShape(Circle())
            .background(AppColor.raised, in: Circle())
            .overlay(Circle().stroke(bot.accentColor.flatMap(Color.init(hex:)) ?? AppColor.separator, lineWidth: bot.accentColor == nil ? 0.75 : 1.5))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    }
}

struct NeutralPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: .textBackgroundColor)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension Color {
    /// `#RRGGBB` → Color; nil for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension Notification.Name {
    static let toggleInfo = Notification.Name("AgentApp.toggleInfo")
    static let newBot = Notification.Name("AgentApp.newBot")
    static let commandPalette = Notification.Name("AgentApp.commandPalette")
}
