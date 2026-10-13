import Foundation
import Testing
@testable import AgentApp

/// P15 Part B: Grok's words, the 11 colours and the default-look rule (synthetic ids only).
@Suite struct AvatarModelTests {
    @Test func elevenColoursWithKonradsSwatchesAndBlackFlipsInDark() {
        #expect(AvatarColour.allCases.map(\.hex) == ["#000000", "#936439", "#FF263C", "#FF6700", "#FF9800", "#00C972", "#00BCA6",
                                                    "#1084FE", "#9159FE", "#FF309B", "#777777"])
        #expect(AvatarColour.black.hex(dark: true) == "#FFFFFF" && AvatarColour.black.hex(dark: false) == "#000000")
        for colour in AvatarColour.allCases where colour != .black { #expect(colour.hex(dark: true) == colour.hex) }
        #expect(GrokDefaultLook.colours == AvatarColour.allCases.filter { $0 != .black })
    }

    @Test func twentyFiveValidShapesIncludeTheDerivableEight() {
        #expect(AvatarShape.valid.count == 25 && Set(AvatarShape.valid).count == 25)
        #expect(GrokDefaultLook.shapes.allSatisfy(AvatarShape.isValid))
        #expect(!AvatarShape.isValid("Blob") && !AvatarShape.isValid("hexagon"))
    }

    @Test(arguments: [
        ("", UInt32(0x811C_9DC5), 5, 6, "hex", "blue"),
        ("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", 0x6152_99A2, 1, 2, "pebble", "orange"),
        ("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", 0x0CEB_1322, 2, 0, "squircle", "brown"),
        ("zolw-\u{1F642}", 0x2584_CD0D, 7, 9, "teardrop", "gray")
    ])
    func defaultLookVectors(id: String, fnv: UInt32, shape: Int, colour: Int, shapeWord: String, colourWord: String) {
        let hash = GrokDefaultLook.fnv1a(id)
        #expect(hash == fnv)
        #expect(GrokDefaultLook.shapeIndex(hash) == shape && GrokDefaultLook.colourIndex(hash) == colour)
        #expect(GrokDefaultLook.mark(for: id) == AvatarMark(shape: shapeWord, colour: colourWord))
    }

    @Test func defaultLookIsCaseAndSurrogateSensitive() {
        let lower = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        #expect(GrokDefaultLook.mark(for: lower) != GrokDefaultLook.mark(for: lower.uppercased()))
        // UTF-16 units, not scalars or bytes: the emoji is two units (a surrogate pair).
        let emoji = "zolw-\u{1F642}"
        #expect(emoji.utf16.count == 7)
        var manual: UInt32 = 0x811C_9DC5
        for unit in [0x7A, 0x6F, 0x6C, 0x77, 0x2D, 0xD83D, 0xDE42] as [UInt32] { manual = (manual ^ unit) &* 0x0100_0193 }
        #expect(GrokDefaultLook.fnv1a(emoji) == manual)
        #expect(GrokDefaultLook.fnv1a("zolw-\u{263A}") != manual)
    }

    @Test func resolveKeepsValidWordsAndDerivesEachInvalidField() {
        let seed = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" // derives pebble/orange
        #expect(AvatarLook.resolve(mark: nil, classic: .fox, seed: seed) == .classic(.fox))
        #expect(AvatarLook.resolve(mark: AvatarMark(shape: "shield", colour: "black"), classic: .fox, seed: seed) == .mark(shape: "shield", colour: .black))
        #expect(AvatarLook.resolve(mark: AvatarMark(shape: "Shield", colour: "black"), classic: .fox, seed: seed) == .mark(shape: "pebble", colour: .black))
        #expect(AvatarLook.resolve(mark: AvatarMark(shape: "gem", colour: "pink"), classic: .fox, seed: seed) == .mark(shape: "gem", colour: .orange))
        #expect(AvatarLook.resolve(mark: AvatarMark(shape: "", colour: ""), classic: .fox, seed: seed) == .mark(shape: "pebble", colour: .orange))
    }

    @Test func seedIsTheGrokIdVerbatimElseTheLowercasedUUID() {
        let bot = Bot(name: "Seed", avatarName: .faceSky)
        #expect(bot.avatarSeed == bot.id.uuidString.lowercased())
        bot.grokSourceID = "AbC-not-a-uuid"
        #expect(bot.avatarSeed == "AbC-not-a-uuid")
    }

    @Test func newBotWithoutAClassicChoiceGetsItsDerivedMark() {
        let derived = Bot(name: "New")
        #expect(derived.avatarMark == GrokDefaultLook.mark(for: derived.id.uuidString.lowercased()) && derived.avatarName == .faceCoral)
        let classic = Bot(name: "Classic", avatarName: .faceSun)
        #expect(classic.avatarMark == nil && classic.avatarLook == .classic(.faceSun))
    }
}
