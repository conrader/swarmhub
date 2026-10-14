import Foundation
import Testing
@preconcurrency import BotAvatarsKit
@testable import AgentApp

/// P15 item 9: every Grok word has a kit body; the roster stays distinguishable; the known collisions are pinned.
@Suite struct AvatarKitMapTests {
    @Test func everyValidWordResolvesAndOnlyTheNamedOnesAreClose() {
        let close = Set(["blob", "cloud", "hex", "teardrop", "wedge", "clover", "flower", "star", "pebble", "tablet", "square", "squircle"] + BotAvatarType.allCases.map(\.rawValue))
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

    @Test func pickerOffersNativeBodiesOnceIncludingCircle() {
        let bodies = AvatarKitMap.pickerShapes.map { AvatarKitMap.body(for: $0).type }
        #expect(Set(bodies) == Set(BotAvatarType.allCases))
        #expect(bodies.count == Set(bodies).count)
        #expect(AvatarKitMap.pickerShapes.contains("circle"))
        #expect(AvatarKitMap.pickerShapes.allSatisfy(AvatarShape.isValid))
        #expect(AvatarKitMap.pickerShapes.allSatisfy { !AvatarKitMap.body(for: $0).approximate })
        #expect(!AvatarKitMap.pickerShapes.contains { ["heart", "house", "sparkle"].contains($0) })
    }

    @Test @MainActor func shapeAndColourSelectionsPreviewAndPersistTheExactChoice() throws {
        let url = temporaryStore()
        let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Picker test"); store.bots = [bot]
        for shape in AvatarKitMap.pickerShapes {
            var choice = AvatarChoice.mark(shape: "star", colour: "blue")
            choice.selectShape(shape, seed: bot.avatarSeed)
            #expect(choice.previewMark(seed: bot.avatarSeed) == AvatarMark(shape: shape, colour: "blue"))
            choice.selectColour(.orange, seed: bot.avatarSeed)
            #expect(choice.previewMark(seed: bot.avatarSeed) == AvatarMark(shape: shape, colour: "orange"))
            choice.apply(to: bot); store.save()
            let restored = try StoreFile.decode(Data(contentsOf: url))
            #expect(restored.bots.first?.avatarMark == AvatarMark(shape: shape, colour: "orange"))
            #expect(restored.bots.first?.avatarLook == .mark(shape: shape, colour: .orange))
        }
    }

    @Test func changingAColourKeepsTheExistingShapeAndChangingAShapeKeepsTheColour() {
        let seed = "picker-test"
        var choice = AvatarChoice.mark(shape: "gem", colour: "violet")
        choice.selectColour(.green, seed: seed)
        #expect(choice == .mark(shape: "gem", colour: "green"))
        choice.selectShape("circle", seed: seed)
        #expect(choice == .mark(shape: "circle", colour: "green"))
        var legacy = AvatarChoice.classic(.fox)
        legacy.selectShape("circle", seed: seed)
        #expect(legacy.previewMark(seed: seed).shape == "circle")
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
