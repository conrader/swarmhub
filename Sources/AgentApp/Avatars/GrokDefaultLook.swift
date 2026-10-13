import Foundation

/// Grok Bot's default look for a bot with no avatar words, reimplemented as our own code from the rule read in
/// Grok Bot 0.70.2 (briefs/P15.md item 6). The constants are frozen once shipped: changing one changes every derived bot.
enum GrokDefaultLook {
    static let shapes = ["blob", "pebble", "squircle", "tablet", "wedge", "hex", "cloud", "teardrop"]
    /// Every colour but black.
    static let colours: [AvatarColour] = [.brown, .red, .orange, .yellow, .green, .cyan, .blue, .violet, .magenta, .gray]

    /// 32-bit FNV-1a over the id's UTF-16 code units (as JavaScript's `charCodeAt`).
    static func fnv1a(_ id: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for unit in id.utf16 { hash = (hash ^ UInt32(unit)) &* 0x0100_0193 }
        return hash
    }

    static func shapeIndex(_ hash: UInt32) -> Int {
        var x = hash
        x = (x ^ (x >> 16)) &* 0x045D_9F3B
        x = (x ^ (x >> 13)) &* 0xC2B2_AE35
        x ^= x >> 16
        return Int(x % UInt32(shapes.count))
    }

    /// The first output of mulberry32 seeded with `hash`, scaled to the ten colours.
    static func colourIndex(_ hash: UInt32) -> Int {
        let t = hash &+ 0x6D2B_79F5
        var n = (t ^ (t >> 15)) &* (t | 1)
        n = (n &+ ((n ^ (n >> 7)) &* (n | 61))) ^ n
        let r = n ^ (n >> 14)
        return Int((UInt64(r) * UInt64(colours.count)) >> 32)
    }

    static func mark(for id: String) -> AvatarMark {
        let hash = fnv1a(id)
        return AvatarMark(shape: shapes[shapeIndex(hash)], colour: colours[colourIndex(hash)].rawValue)
    }
}
