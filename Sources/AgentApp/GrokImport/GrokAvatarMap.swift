import Foundation

/// Maps a Grok Bot avatar description (shape + colour words) to Torvli's own avatars and accent colours.
/// Only the words are read; no Grok artwork is copied or referenced.
enum GrokAvatarMap {
    static let shapes: [String: BotAvatarName] = [
        "blob": .blob, "cylinder": .coffee, "shield": .robot, "gem": .planet, "hex": .bubble, "leaf": .pebble
    ]
    static let colourFaces: [String: BotAvatarName] = [
        "black": .facePlum, "violet": .faceLilac, "blue": .faceBlue, "yellow": .faceSun, "orange": .facePeach, "green": .faceMint
    ]
    /// Torvli accent palette (hex RGB), keyed by the Grok colour word.
    static let accents: [String: String] = [
        "black": "#55555C", "violet": "#8E6CD8", "blue": "#4A7FD6", "yellow": "#E0B83A", "orange": "#E8873A", "green": "#4DA866"
    ]
    private static let fallbackFaces: [BotAvatarName] = BotAvatarName.allCases.filter(\.isFlatFace)

    /// Shape picks the avatar; without a known shape the colour picks a face; with neither, a face is
    /// chosen deterministically from the source id so re-imports keep the same look.
    static func map(shape: String?, colour: String?, sourceID: String) -> (avatar: BotAvatarName, accent: String?) {
        let shape = shape?.lowercased(), colour = colour?.lowercased()
        let accent = colour.flatMap { accents[$0] }
        if let shape, let avatar = shapes[shape] { return (avatar, accent) }
        if let colour, let face = colourFaces[colour] { return (face, accent) }
        let sum = sourceID.utf8.reduce(0) { ($0 &+ Int($1)) % 9973 }
        return (fallbackFaces[sum % fallbackFaces.count], accent)
    }
}
