import Foundation
import Testing
@testable import AgentApp

/// What a chosen or an on state is drawn with, measured: with each of the app's own accents, in light and dark, on
/// every surface a control lies on. Words and marks read at 4.5:1; the edge of a control can be seen at 3:1.
/// The views draw exactly these numbers (`AppColor` and `AppTheme` are built from `Palette`).
struct SelectedStateTests {
    private static let accents = ["Blue", "Clay", "Sage", "Graphite"]
    private static let surfaces: [(name: String, pair: Palette.Pair)] = [("sidebar", Palette.sidebar), ("chat", Palette.chat), ("panel", Palette.panel), ("card", Palette.card), ("raised", Palette.raised)]

    private func each(_ check: (_ accent: RGB, _ on: RGB, _ text: RGB, _ dark: Bool, _ place: String) -> Void) {
        for name in Self.accents {
            for dark in [false, true] {
                check(Palette.accent(name, dark: dark), Palette.rgb(Palette.onAccent, dark: dark), Palette.rgb(Palette.graphite, dark: dark), dark, "\(name), \(dark ? "dark" : "light")")
            }
        }
    }

    @Test func wordsAndTicksOnAChosenFillCanBeRead() {
        // A chosen tile, the chosen segment, the shown tab, a picked option, a default button, the tick in a mark.
        each { accent, on, _, _, place in
            #expect(on.contrast(with: accent) >= 4.5, "\(place): \(on.contrast(with: accent))")
        }
    }

    @Test func aChosenFillStandsOutFromEverySurface() {
        each { accent, _, _, dark, place in
            for surface in Self.surfaces {
                let ratio = accent.contrast(with: Palette.rgb(surface.pair, dark: dark))
                #expect(ratio >= 3, "\(place), on \(surface.name): \(ratio)")
            }
        }
    }

    @Test func whatIsNotChosenHasAnEdgeThatCanBeSeen() {
        // The outline of a tile, an option or a segmented control that is not chosen, and the track of a switch that is off.
        for dark in [false, true] {
            let outline = Palette.rgb(Palette.outline, dark: dark)
            for surface in Self.surfaces {
                let ratio = outline.contrast(with: Palette.rgb(surface.pair, dark: dark))
                #expect(ratio >= 3, "\(dark ? "dark" : "light"), on \(surface.name): \(ratio)")
            }
            // The white knob of a switch that is off, on its track.
            #expect(RGB.white.contrast(with: outline) >= 3)
        }
    }

    @Test func aChosenCardIsWashedOutlinedAndStillReadable() {
        // A large option: washed with the accent, outlined in it, ticked. Its words stay in the text colour.
        each { accent, on, text, dark, place in
            for surface in Self.surfaces where surface.name != "sidebar" {
                let under = Palette.rgb(Palette.raised, dark: dark)
                let wash = accent.over(under, opacity: Chosen.wash)
                #expect(text.contrast(with: wash) >= 4.5, "\(place): the title on the wash")
                #expect(accent.contrast(with: Palette.rgb(surface.pair, dark: dark)) >= 3, "\(place): the outline on \(surface.name)")
                #expect(wash != under, "\(place): a chosen card is not the colour of the one beside it")
                #expect(on.contrast(with: accent) >= 4.5, "\(place): its tick")
            }
        }
    }

    @Test func theOpenChatIsWashedAndMarkedInTheSidebar() {
        each { accent, _, text, dark, place in
            let sidebar = Palette.rgb(Palette.sidebar, dark: dark), row = accent.over(sidebar, opacity: SidebarMetrics.selectionWash)
            #expect(text.contrast(with: row) >= 4.5, "\(place): the bot's name on its row")
            #expect(accent.contrast(with: row) >= 3, "\(place): the mark at the row's edge: \(accent.contrast(with: row))")
            #expect(row.contrast(with: sidebar) >= 1.15, "\(place): the row against the sidebar: \(row.contrast(with: sidebar))")
        }
    }

    @Test func aSwitchThatIsOnShowsItsKnob() {
        // Graphite on a dark window was a white knob on a white track.
        each { accent, on, _, _, place in
            #expect(on.contrast(with: accent) >= 3, "\(place): the knob on the track")
        }
    }

    @Test func theSmallActionsUnderAMessageCanBeSeen() {
        for dark in [false, true] {
            let mark = Palette.rgb(Palette.mark, dark: dark)
            for surface in Self.surfaces {
                let ratio = mark.contrast(with: Palette.rgb(surface.pair, dark: dark))
                #expect(ratio >= 4.5, "\(dark ? "dark" : "light"), on \(surface.name): \(ratio)")
            }
        }
    }

    @Test func theSystemsOwnAccentsReadOnADarkWindow() {
        // Blue, Purple, Pink, Orange and Teal are the system's colours, near enough in `Palette.system`. On a dark
        // window the charcoal ink reads on all of them. On a light one the ink is white, as the system writes on
        // them itself, which on its Orange and Teal is below 3:1: those accents are not measured here.
        for name in AppTheme.accentNames where !Self.accents.contains(name) {
            let ratio = Palette.rgb(Palette.onAccent, dark: true).contrast(with: Palette.accent(name, dark: true))
            #expect(ratio >= 4.5, "\(name), dark: \(ratio)")
        }
    }

    @Test func anAccentNobodyKnowsIsClay() {
        #expect(Palette.accent("Nothing", dark: false) == Palette.rgb(Palette.clay, dark: false))
        #expect(AppTheme.accentNames.contains(AppTheme.defaultAccent))
    }
}
