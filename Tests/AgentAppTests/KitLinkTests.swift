import Testing
import SwiftUI
@preconcurrency import BotAvatarsKit

/// The vendored kit links into the test target and its app patches are present.
@Suite struct KitLinkTests {
    @Test @MainActor func drawConfigBuildsAndClockReportsRunning() {
        var config = BotAvatarDrawConfig(type: .blob, color: BotColor("#1084FE"))
        config.shading = .flat
        config.still = true
        #expect(config.typeKey == "blob")
        #expect(config.color == BotColor("#1084FE"))
        #expect(BotAvatarClock.shared.isRunning == false)
    }

    @Test func colourFromSwiftUIResolvesInSRGB() {
        let colour = BotColor(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
        #expect(abs(colour.r - 255) < 0.5 && colour.g < 0.5 && colour.b < 0.5)
    }
}
