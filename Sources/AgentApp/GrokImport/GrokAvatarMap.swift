import Foundation

/// Maps a Grok Bot avatar description (shape + colour words) to the mark the app stores. Only the words are read; no Grok
/// artwork is copied or referenced. The P6 tables below are what the old importer wrote into `avatarName`/`accentColor`;
/// they are kept, frozen, so `AvatarMigration` can recognise those bots.
enum GrokAvatarMap {
    static let shapes: [String: BotAvatarName] = [
        "blob": .blob, "cylinder": .coffee, "shield": .robot, "gem": .planet, "hex": .bubble, "leaf": .pebble
    ]
    static let colourFaces: [String: BotAvatarName] = [
        "black": .facePlum, "violet": .faceLilac, "blue": .faceBlue, "yellow": .faceSun, "orange": .facePeach, "green": .faceMint
    ]
    /// P6 accent palette (hex RGB), keyed by the Grok colour word.
    static let accents: [String: String] = [
        "black": "#55555C", "violet": "#8E6CD8", "blue": "#4A7FD6", "yellow": "#E0B83A", "orange": "#E8873A", "green": "#4DA866"
    ]
    private static let fallbackFaces: [BotAvatarName] = BotAvatarName.allCases.filter(\.isFlatFace)

    /// The effective mark: each word as stored when Grok accepts it (case-sensitive), else derived from the source id.
    static func map(shape: String?, colour: String?, sourceID: String) -> AvatarMark {
        AvatarLook.effectiveMark(shape: shape, colour: colour, seed: sourceID)
    }

    /// The face P6 chose when a bundle had neither a known shape nor a known colour.
    static func legacyFallbackFace(sourceID: String) -> BotAvatarName {
        let sum = sourceID.utf8.reduce(0) { ($0 &+ Int($1)) % 9973 }
        return fallbackFaces[sum % fallbackFaces.count]
    }
}
