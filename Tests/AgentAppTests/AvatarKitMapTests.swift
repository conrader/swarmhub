import Foundation
import Testing
@preconcurrency import BotAvatarsKit
@testable import AgentApp

/// P15 item 9: every Grok word has a kit body; the roster stays distinguishable; the known collisions are pinned.
@Suite struct AvatarKitMapTests {
    @Test func everyValidWordResolvesAndOnlyTheNamedOnesAreClose() {
        let close: Set<String> = ["blob", "cloud", "hex", "teardrop", "wedge", "clover", "flower", "star", "pebble", "tablet", "square", "squircle"]
        for word in AvatarShape.valid {
            #expect(AvatarKitMap.body(for: word).approximate == !close.contains(word), "\(word)")
        }
        #expect(AvatarKitMap.body(for: "Blob").approximate)
    }

    @Test func approximationsAndCollisionsArePinned() {
        func type(_ word: String) -> BotAvatarType { AvatarKitMap.body(for: word).type }
        #expect(type("gem") == .hexagon && type("hex") == .hexagon)      // Finance Controller and Reactor: two hexagons
        #expect(type("leaf") == .drop && type("teardrop") == .drop)      // DMT and Doc differ by colour only
        #expect(type("shield") == .alien && type("cylinder") == .pill)
        #expect(type("tablet") == .square && type("squircle") == .square && type("square") == .square)
        #expect(type("wedge") == .triangle && type("blob") == .blob && type("cloud") == .cloud)
    }

    @Test func sixteenRosterPairsStayDistinct() {
        let roster = AvatarRosterLocalTests.expected.values.map { $0.split(separator: "/").map(String.init) }
        #expect(roster.count == 16)
        let pairs = Set(roster.map { "\(AvatarKitMap.body(for: $0[0]).type.rawValue)/\($0[1])" })
        #expect(pairs.count == 16)
    }

    @Test func pickerOffersSixteenShapesWithABodyButNotHeartHouseSparkle() {
        #expect(AvatarKitMap.pickerShapes.count == 16 && Set(AvatarKitMap.pickerShapes).count == 16)
        #expect(AvatarKitMap.pickerShapes.allSatisfy(AvatarShape.isValid))
        #expect(!AvatarKitMap.pickerShapes.contains { ["heart", "house", "sparkle"].contains($0) })
    }

    @Test func stillConfigIsFlatWithoutRimAndKitSeedIsInRange() {
        let config = AvatarStillMark.config(type: .alien, colourHex: AvatarColour.yellow.hex)
        #expect(config.shading == .flat && config.rim == 0 && config.still && config.color == BotColor("#FF9800"))
        for seed in ["", "x", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"] { #expect((0..<1).contains(AvatarKitMap.kitSeed(seed))) }
    }

    @Test @MainActor func editorChoiceAppliesMarksAndClassicPicks() {
        let bot = Bot(name: "E", avatarName: .faceSky)
        AvatarChoice.mark(shape: "star", colour: nil).apply(to: bot)
        #expect(bot.avatarMark == AvatarMark(shape: "star", colour: GrokDefaultLook.mark(for: bot.avatarSeed).colour))
        AvatarChoice.classic(.fox).apply(to: bot)
        #expect(bot.avatarMark == nil && bot.avatarName == .fox)
        #expect(AvatarChoice(bot: bot) == .classic(.fox))
    }
}
