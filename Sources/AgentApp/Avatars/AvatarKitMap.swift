import Foundation
@preconcurrency import BotAvatarsKit

/// Grok shape word → the BotAvatarsKit body drawn for it. The word stays the stored truth; the body is resolved at
/// render. Where the kit has no matching body the nearest one is used and flagged `approximate` (briefs/P15.md item 9):
/// gem → hexagon (as hex), leaf → drop (as teardrop), shield → alien (a head with a chin), cylinder → pill (flat).
enum AvatarKitMap {
    struct Body: Equatable, Sendable {
        let type: BotAvatarType
        let approximate: Bool
    }

    private static let close: [String: BotAvatarType] = [
        "blob": .blob, "cloud": .cloud, "hex": .hexagon, "teardrop": .drop, "wedge": .triangle, "clover": .clover, "flower": .flower,
        "star": .star, "pebble": .pebble, "tablet": .square, "square": .square, "squircle": .square
    ]
    private static let approximations: [String: BotAvatarType] = [
        "gem": .hexagon, "leaf": .drop, "shield": .alien, "cylinder": .pill,
        "bean": .pebble, "egg": .pebble, "capsule": .pill, "crystal": .hexagon, "dome": .ghost, "arch": .ghost,
        "sparkle": .star, "heart": .circle, "house": .square
    ]

    static func body(for shape: String) -> Body {
        if let type = close[shape] { return Body(type: type, approximate: false) }
        return Body(type: approximations[shape] ?? .blob, approximate: true)
    }

    /// The editor's 16 shapes: the 10 roster shapes, pebble, squircle, square, clover, flower, star.
    /// Not offered: heart, house, sparkle (no kit body).
    static let pickerShapes = ["blob", "cylinder", "gem", "hex", "leaf", "shield", "cloud", "tablet", "wedge", "teardrop",
                               "pebble", "squircle", "square", "clover", "flower", "star"]

    /// The kit's 0–1 animation seed from the bot's look seed, so marks of different bots do not blink in lockstep.
    static func kitSeed(_ seed: String) -> Double { Double(GrokDefaultLook.fnv1a(seed)) / 4_294_967_296 }
}
