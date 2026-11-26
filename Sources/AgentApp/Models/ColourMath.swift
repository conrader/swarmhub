import Foundation

/// A colour as numbers, so that what the app draws can be checked by measurement: how much two colours differ
/// (WCAG's contrast ratio), what a wash of one over another gives, and a version of a colour that can be read as
/// text. Foundation only; the views turn the result into a `Color`.
struct RGB: Equatable, Hashable, Sendable {
    var red: Double, green: Double, blue: Double

    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
    /// `#RRGGBB`; nil for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    var hex: UInt32 {
        func part(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return part(red) << 16 | part(green) << 8 | part(blue)
    }

    static let white = RGB(0xFFFFFF), black = RGB(0x000000)

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    func contrast(with other: RGB) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// This colour at `opacity` over `base`.
    func over(_ base: RGB, opacity: Double) -> RGB {
        RGB(red: red * opacity + base.red * (1 - opacity), green: green * opacity + base.green * (1 - opacity), blue: blue * opacity + base.blue * (1 - opacity))
    }

    /// How far the colour is from grey: 0 for white, black and every grey, 1 for a pure colour.
    var chroma: Double { max(red, green, blue) - min(red, green, blue) }

    /// The same hue moved towards white (`amount` > 0) or black (`amount` < 0), by a share of the way there.
    func shifted(_ amount: Double) -> RGB {
        let target = amount >= 0 ? RGB.white : RGB.black, share = min(abs(amount), 1)
        return RGB(red: red + (target.red - red) * share, green: green + (target.green - green) * share, blue: blue + (target.blue - blue) * share)
    }

    /// This colour as text on `surface`: itself when it already reads at `ratio`, otherwise moved towards white (on a
    /// dark surface) or black (on a light one) just far enough.
    func readable(on surface: RGB, ratio: Double = 4.5) -> RGB {
        if contrast(with: surface) >= ratio { return self }
        let lighten = surface.luminance < 0.18
        for step in 1...50 {
            let candidate = shifted(Double(step) / 50 * (lighten ? 1 : -1))
            if candidate.contrast(with: surface) >= ratio { return candidate }
        }
        return lighten ? .white : .black
    }
}

/// A bot's colour as the chat uses it, in one scheme: `fill` washes and outlines what the bot says (its cards, its
/// header), and `ink` writes its name and marks on those surfaces. Both come from the colour of its avatar. An avatar
/// that is white, black or grey has no hue to borrow, so it gets the icon's cream (on dark) or ink (on light): a
/// visible, warm accent instead of white on white.
struct BotTintPair: Equatable, Sendable {
    let fill: RGB, ink: RGB

    /// How strongly a card is washed and outlined with `fill`.
    static let wash = 0.13, border = 0.40
    /// Below this a colour counts as grey.
    static let greyChroma = 0.10
    /// What a grey avatar gets, light to dark: cream for a white one, a warm stone for a mid grey, umber for a black one.
    static let cream = RGB(0xEDE8D6), stoneOnDark = RGB(0xBDB8A2), stoneOnLight = RGB(0x7D7259), inkOnLight = RGB(0x4A3F2B)

    /// `colour`: the avatar's colour as it is drawn in this scheme. `surface`: what the bot's cards lie on.
    /// `also`: other surfaces a card of this colour lies on (the card surface above the message box), so that `ink`
    /// reads on all of them.
    init(avatar colour: RGB, dark: Bool, surface: RGB, also: [RGB] = []) {
        let base: RGB
        if colour.chroma < Self.greyChroma {
            let light = colour.luminance
            if dark { base = light > 0.5 ? Self.cream : Self.stoneOnDark }
            else { base = light < 0.12 ? Self.inkOnLight : Self.stoneOnLight }
        } else {
            // A colour so dark (on dark) or so pale (on light) that a wash of it would not show is brought into range.
            let ratio = colour.contrast(with: surface)
            base = ratio >= 2.2 ? colour : colour.readable(on: surface, ratio: 2.2)
        }
        fill = base
        ink = ([surface] + also).reduce(base) { ink, under in ink.readable(on: Self.cardSurface(fill: base, on: under)) }
    }

    /// The surface of a card washed with `fill`.
    static func cardSurface(fill: RGB, on surface: RGB) -> RGB { fill.over(surface, opacity: wash) }
    var cardBorderOpacity: Double { Self.border }
}

/// The app's surfaces and accents as numbers (`AppColor` and `AppTheme` draw exactly these), so tests can measure
/// what a control or a card looks like on each of them.
enum Palette {
    typealias Pair = (light: UInt32, dark: UInt32)
    static let sidebar: Pair = (0xF5F5F7, 0x0C0C0F), chat: Pair = (0xFFFFFF, 0x111114), panel: Pair = (0xF8F9FB, 0x0E0E11)
    static let card: Pair = (0xF8F9FB, 0x17171D), raised: Pair = (0xFFFFFF, 0x19191F)
    static let separator: Pair = (0xDCDDE0, 0x303037), selection: Pair = (0xE2E4EB, 0x25252B)
    /// The line around a control that is not chosen (a tile, a switch that is off), and the mark inside one that is.
    static let outline: Pair = (0x7A7D89, 0x7C7F8C)
    /// Small marks drawn straight on a surface (the actions under a message): 4.5:1 on every surface.
    static let mark: Pair = (0x5B6070, 0xA3A5B0)
    /// What is written or drawn on a fill of the accent: white on a light window, charcoal on a dark one, where the
    /// accents are brighter. Either reads at 4.5:1 on Clay, Sage and Graphite.
    static let onAccent: Pair = (0xFFFFFF, 0x111114)
    static let clay: Pair = (0xB84A1E, 0xD97A3E), sage: Pair = (0x55784F, 0x7FA079)
    /// Graphite follows the text colour.
    static let graphite: Pair = (0x111318, 0xF4F4F6)
    /// The system's own accents, near enough to derive a tint from; the app draws the system's colour itself.
    static let system: [String: Pair] = ["Blue": (0x2563EB, 0x5B93FF), "Purple": (0xAF52DE, 0xBF5AF2), "Pink": (0xFF2D55, 0xFF375F), "Orange": (0xFF9500, 0xFF9F0A),
                                         "Green": (0x34C759, 0x30D158), "Teal": (0x30B0C7, 0x40C8E0)]

    static func rgb(_ pair: Pair, dark: Bool) -> RGB { RGB(dark ? pair.dark : pair.light) }

    /// The accent of that name as numbers; anything unknown is Clay, as in `AppTheme.accentColor`.
    static func accent(_ name: String, dark: Bool) -> RGB {
        switch name {
        case "Sage": rgb(sage, dark: dark)
        case "Graphite": rgb(graphite, dark: dark)
        default: system[name].map { rgb($0, dark: dark) } ?? rgb(clay, dark: dark)
        }
    }
}
