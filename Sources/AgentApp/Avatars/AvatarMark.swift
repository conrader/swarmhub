import Foundation

/// A Grok-style bot mark as Grok stores it: a shape word and a colour word, kept verbatim (open sets, never kit enums).
/// The body the kit draws is resolved at render time (`AvatarKitMap`); these words stay the stored truth.
struct AvatarMark: Codable, Equatable, Hashable, Sendable {
    var shape: String
    var colour: String
}

/// The shape words Grok Bot 0.70.2's engine accepts (docs/avatars-research.md), case-sensitive as Grok.
enum AvatarShape {
    static let valid: [String] = [
        "blob", "pebble", "bean", "egg", "squircle", "tablet", "capsule", "cylinder", "hex", "gem", "crystal", "wedge", "shield",
        "dome", "arch", "cloud", "teardrop", "leaf", "square", "sparkle", "clover", "flower", "heart", "house", "star"
    ]
    static func isValid(_ word: String) -> Bool { valid.contains(word) }
}

/// Grok's 11 picker colours (Konrad's swatches); black shows white in dark mode.
enum AvatarColour: String, CaseIterable, Sendable {
    case black, brown, red, orange, yellow, green, cyan, blue, violet, magenta, gray

    var hex: String {
        switch self {
        case .black: "#000000"; case .brown: "#936439"; case .red: "#FF263C"; case .orange: "#FF6700"
        case .yellow: "#FF9800"; case .green: "#00C972"; case .cyan: "#00BCA6"; case .blue: "#1084FE"
        case .violet: "#9159FE"; case .magenta: "#FF309B"; case .gray: "#777777"
        }
    }

    /// The fill on screen: black flips to white in dark mode, every other colour is its swatch.
    func hex(dark: Bool) -> String { self == .black && dark ? "#FFFFFF" : hex }
}

/// What a bot shows: a mark (a valid shape word and one of the 11 colours) or a classic app avatar.
enum AvatarLook: Equatable, Sendable {
    case mark(shape: String, colour: AvatarColour)
    case classic(BotAvatarName)

    /// No mark → the classic avatar; else each field is the stored word if exactly valid, otherwise derived from `seed`.
    static func resolve(mark: AvatarMark?, classic: BotAvatarName, seed: String) -> AvatarLook {
        guard let mark else { return .classic(classic) }
        let effective = effectiveMark(shape: mark.shape, colour: mark.colour, seed: seed)
        return .mark(shape: effective.shape, colour: AvatarColour(rawValue: effective.colour) ?? .gray)
    }

    /// The words Grok would draw: each stored word when valid (case-sensitive), else the id-derived default for that field.
    static func effectiveMark(shape: String?, colour: String?, seed: String) -> AvatarMark {
        let derived = GrokDefaultLook.mark(for: seed)
        let shape = shape.flatMap { AvatarShape.isValid($0) ? $0 : nil } ?? derived.shape
        let colour = colour.flatMap { AvatarColour(rawValue: $0) != nil ? $0 : nil } ?? derived.colour
        return AvatarMark(shape: shape, colour: colour)
    }
}

extension Bot {
    /// The id Grok derives a default look from: the Grok source id verbatim, else this bot's id in lower case.
    var avatarSeed: String { grokSourceID ?? id.uuidString.lowercased() }
    var avatarLook: AvatarLook { AvatarLook.resolve(mark: avatarMark, classic: avatarName, seed: avatarSeed) }
}
