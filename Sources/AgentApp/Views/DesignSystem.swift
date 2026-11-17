import AppKit
import SwiftUI

enum AppTheme {
    static let defaultPreference = "Dark"
    /// Clay, from the app icon: warm, and the colour of every default button, switch and selection until the person
    /// picks another. Graphite (the earlier default) is still offered.
    static let defaultAccent = "Clay"
    static let accentNames = ["Clay", "Sage", "Blue", "Purple", "Pink", "Orange", "Teal", "Graphite"]

    /// The app-wide tint. Clay and Sage are the icon's own colours, deepened until white text on a button reads
    /// (4.5:1 in light, 3.4:1 in dark, where the same tint is also text on the dark surface at 4.8:1); Graphite
    /// follows the primary text colour; anything unknown is Clay.
    static func accentColor(for name: String) -> Color {
        switch name {
        case "Sage": AppColor.adaptive(Palette.sage)
        case "Blue": .blue
        case "Purple": .purple
        case "Pink": .pink
        case "Orange": .orange
        case "Green": .green
        case "Teal": .teal
        case "Graphite": .primary
        default: AppColor.adaptive(Palette.clay)
        }
    }

    /// What is written or drawn on a fill of the accent (a tick on a chosen tile, the label of a default button):
    /// white, except on Graphite, whose fill is the text colour itself.
    static func onAccent(for name: String) -> Color { name == "Graphite" ? Color(nsColor: .textBackgroundColor) : .white }

    static func colorScheme(for preference: String) -> ColorScheme? {
        switch preference {
        case "Light": .light
        case "System": nil
        default: .dark
        }
    }
}

/// The app's colours, drawn from its icon ("Crew": cream, olive, sage and clay). Surfaces are warm neutrals, cream in
/// light and olive charcoal in dark, never a blue-grey or a pure black; the few named colours mark states and tiles.
/// Text on every surface is the system's primary and secondary, which read at 12:1 and more on all of them.
enum AppColor {
    static let sidebar = adaptive(Palette.sidebar)
    static let chat = adaptive(Palette.chat)
    static let panel = adaptive(Palette.panel)
    static let card = adaptive(Palette.card)
    static let raised = adaptive(Palette.raised)
    static let separator = adaptive(Palette.separator)
    static let selection = adaptive(Palette.selection)
    /// The line around a control that is not chosen: 3:1 on every surface above, so the control's edge can be seen.
    static let outline = adaptive(Palette.outline)

    // The icon's faces, for tiles and marks.
    static let clay = adaptive(light: 0xD98F58, dark: 0xE0A070)
    static let sage = adaptive(light: 0x7FA079, dark: 0x8FAE8A)
    static let olive = adaptive(light: 0x5C5F4C, dark: 0x8C8F78)
    // Three quiet companions, so a screen with several tiles is not all one colour.
    static let sky = adaptive(light: 0x6F9BC0, dark: 0x86AED0)
    static let plum = adaptive(light: 0xA283B4, dark: 0xB79AC6)
    static let sand = adaptive(light: 0xC2A45A, dark: 0xD3B872)

    // States, as text and symbols on any surface above (4.5:1 or more): something is fine, or needs a look.
    static let good = adaptive(light: 0x4B7045, dark: 0x9BBB95)
    static let caution = adaptive(light: 0x9A5B0A, dark: 0xE8B25C)

    static func adaptive(_ pair: Palette.Pair) -> Color { adaptive(light: pair.light, dark: pair.dark) }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
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

extension AvatarColour {
    /// The avatar's colour softened where the swatch is loud, as numbers, in one scheme. Black is drawn white on
    /// dark, and grey is grey: `BotTintPair` gives those a warm neutral.
    func swatch(dark: Bool) -> RGB {
        let pair: Palette.Pair = switch self {
        case .black: (0x000000, 0xFFFFFF)
        case .gray: (0x777777, 0x777777)
        case .brown: (0x936439, 0xB98A60)
        case .red: (0xD8344A, 0xF0707F)
        case .orange: (0xD9641A, 0xF08A45)
        case .yellow: (0xC47F00, 0xF0AE3C)
        case .green: (0x16935C, 0x4CC58F)
        case .cyan: (0x0F9080, 0x45C4B4)
        case .blue: (0x2A78D6, 0x5EA2F2)
        case .violet: (0x7E55D8, 0xA689F5)
        case .magenta: (0xD63A8A, 0xF272B0)
        }
        return Palette.rgb(pair, dark: dark)
    }
}

/// A bot's own colour, for everything it says: the wash and outline of its cards and its header (`fill`), and its
/// name and marks on them (`ink`, which reads at 4.5:1 on a card washed with `fill`). The rule is the same wherever
/// a bot speaks: in its own chat, and in a card that carries its words into another bot's chat.
struct BotTint {
    let fill: Color, ink: Color

    init(light: BotTintPair, dark: BotTintPair) {
        fill = AppColor.adaptive(light: light.fill.hex, dark: dark.fill.hex); ink = AppColor.adaptive(light: light.ink.hex, dark: dark.ink.hex)
    }

    /// From the avatar's colour as drawn in each scheme.
    init(avatar: (light: RGB, dark: RGB)) {
        self.init(light: Self.pair(avatar.light, dark: false), dark: Self.pair(avatar.dark, dark: true))
    }

    /// One scheme's pair: the colour is chosen against the chat, and its ink also reads on the card surface.
    static func pair(_ avatar: RGB, dark: Bool) -> BotTintPair {
        BotTintPair(avatar: avatar, dark: dark, surface: Palette.rgb(Palette.chat, dark: dark), also: [Palette.rgb(Palette.card, dark: dark)])
    }

    /// What the app itself says in a card (a note that is no bot's words): the icon's olive.
    static let app = BotTint(avatar: (RGB(0x5C5F4C), RGB(0x8C8F78)))

    /// A card's surface and outline in this colour, over the chat.
    var wash: Color { fill.opacity(BotTintPair.wash) }
    var border: Color { fill.opacity(BotTintPair.border) }
}

extension Bot {
    /// The avatar's colour in each scheme: its mark's; a classic avatar's own accent, else the app's.
    func avatarRGB(accent: String) -> (light: RGB, dark: RGB) {
        switch avatarLook {
        case .mark(_, let colour): (colour.swatch(dark: false), colour.swatch(dark: true))
        case .classic:
            if let own = accentColor.flatMap(RGB.init(hex:)) { (own, own) } else { (Palette.accent(accent, dark: false), Palette.accent(accent, dark: true)) }
        }
    }

    @MainActor var colours: BotTint { BotTint(avatar: avatarRGB(accent: UserDefaults.standard.string(forKey: "accent") ?? AppTheme.defaultAccent)) }
    /// The colour this bot carries through its chat, as a wash or an outline.
    @MainActor var tint: Color { colours.fill }
    /// The same colour as text.
    @MainActor var tintInk: Color { colours.ink }
}

struct AvatarImage: View {
    let name: BotAvatarName
    var body: some View {
        if name.isFlatFace {
            FlatBotFace(name: name)
        } else {
            Image(nsImage: AvatarAssets.image(named: name.rawValue)).resizable()
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

/// Avatar PNGs: the installed app's Resources/Avatars, the SwiftPM resource bundle next to the binary,
/// or the checkout when run from the package root (tests). `Image(_:bundle: .module)` cannot see them because
/// they are copied as a folder, and `Bundle.module` traps when the bundle is absent.
@MainActor private enum AvatarAssets {
    private static var cache: [String: NSImage] = [:]
    static func image(named name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Avatars/\(name).png"),
            executable.appending(path: "AgentApp_AgentApp.bundle/Avatars/\(name).png"),
            executable.appending(path: "AgentApp.resources/Avatars/\(name).png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Avatars/\(name).png")
        ].compactMap { $0 }
        guard let image = candidates.lazy.compactMap(NSImage.init(contentsOf:)).first else { return NSImage(size: NSSize(width: 28, height: 28)) }
        cache[name] = image
        return image
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
    static let toggleSidebar = Notification.Name("AgentApp.toggleSidebar")
    static let newBot = Notification.Name("AgentApp.newBot")
    static let commandPalette = Notification.Name("AgentApp.commandPalette")
}
