import Foundation

/// Lazy, additive migration of bots stored before marks existed (briefs/P15.md item 8). Runs in `Bot.init(from:)` when
/// no mark is stored and recovers a mark only where the P6 importer provably wrote the avatar; everything else stays
/// classic. Nothing is saved here: the next normal save persists the mark beside the untouched `avatarName`/`accentColor`.
enum AvatarMigration {
    static func mark(avatarName: BotAvatarName, accentColor: String?, grokSourceID: String?) -> AvatarMark? {
        guard let sourceID = grokSourceID else { return nil }
        let accentWord = accentColor.flatMap { hex in GrokAvatarMap.accents.first { $0.value == hex }?.key }
        // A clay the importer chose for a known shape word: that shape, its accent's colour (derived when it had none).
        if let shape = GrokAvatarMap.shapes.first(where: { $0.value == avatarName })?.key {
            if accentColor != nil && accentWord == nil { return nil }
            return AvatarLook.effectiveMark(shape: shape, colour: accentWord, seed: sourceID)
        }
        // A colour face with that colour's accent: the colour was known, the shape was not.
        if let accentWord, GrokAvatarMap.colourFaces[accentWord] == avatarName {
            return AvatarLook.effectiveMark(shape: nil, colour: accentWord, seed: sourceID)
        }
        // The byte-sum fallback face with no accent: Grok had no words, so both are derived.
        if accentColor == nil, avatarName == GrokAvatarMap.legacyFallbackFace(sourceID: sourceID) {
            return GrokDefaultLook.mark(for: sourceID)
        }
        return nil
    }
}
