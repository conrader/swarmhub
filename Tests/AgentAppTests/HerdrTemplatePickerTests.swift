import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor struct HerdrTemplatePickerTests {
    private let claude = Self.template("swarmhub-claude", harness: "Claude Code", display: "Claude")
    private let codex = Self.template("swarmhub-codex", harness: "Codex", display: "Codex")
    private let antigravity = Self.template("swarmhub-antigravity", harness: "Antigravity CLI", display: "Gemini (Antigravity)")

    @Test func runtimeLabelsOnlyDisambiguateWhenTwoTemplatesShareAName() {
        let templates = [claude, codex, antigravity]
        let labels = HerdrProgramName.labels(for: templates)
        #expect(templates.compactMap { labels[$0.name] } == ["Claude", "Codex", "Gemini"])
        for alias in ["Gemini", "Antigravity", "swarmhub-antigravity", "Gemini (Antigravity)"] {
            #expect(HerdrBotRequest.template(for: alias, in: templates) == antigravity)
        }

        let googleCLI = Self.template("swarmhub-gemini", harness: "Gemini CLI", display: "Gemini (beta)")
        let both = [antigravity, googleCLI]
        #expect(HerdrProgramName.labels(for: both) == [
            antigravity.name: "Gemini · swarmhub-antigravity",
            googleCLI.name: "Gemini · swarmhub-gemini",
        ])
        #expect(HerdrBotRequest.template(for: "Gemini (beta)", in: both) == googleCLI)
        #expect(HerdrProgramName.friendly(display: "Gemini (Antigravity) (beta)", program: nil) == "Gemini")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func pickerKeepsItsBoundsAndDefaultBadgeWhenSelectionMoves(scheme: ColorScheme) async throws {
        let defaults = isolatedDefaults()
        defaults.set(scheme == .light ? "Graphite" : "Sage", forKey: "accent")
        func render(selection: String, note: String) async throws -> NSBitmapImageRep {
            let picker = HerdrTemplatePicker(selection: .constant(selection), templates: [claude, codex, antigravity],
                                             defaultName: claude.name, defaultNote: note)
            return try await snapshot(picker.defaultAppStorage(defaults), size: NSSize(width: 490, height: 72), scheme: scheme)
        }

        let inherited = try await render(selection: "", note: "Default")
        let explicit = try await render(selection: codex.name, note: "Default")
        let inheritedWithoutBadge = try await render(selection: "", note: "")
        let withoutBadge = try await render(selection: codex.name, note: "")
        // Three 150 pt tiles at 12, 170, and 328 pt, sampled away from their rounded corners.
        let origins = [12, 170, 328]
        let bounds = origins.map { tileRows(in: inherited, x: $0 + 65) }
        let row = try #require(bounds.first?.first)
        #expect(row.count == 42)
        #expect(bounds == Array(repeating: [row], count: 3))
        #expect(origins.map { tileRows(in: explicit, x: $0 + 65) } == bounds)
        #expect(tileRows(in: withoutBadge, x: origins[0] + 65) == [row])

        let centerY = row.lowerBound + row.count / 2
        let full = pixel(inherited, x: origins[0] + 5, y: centerY)
        let raised = pixel(inherited, x: origins[1] + 5, y: centerY)
        #expect(full != raised)
        #expect(pixel(explicit, x: origins[0] + 5, y: centerY) == raised)
        #expect(pixel(explicit, x: origins[1] + 5, y: centerY) == full)
        #expect(pixel(explicit, x: origins[2] + 5, y: centerY) == raised)
        for (withBadge, plain) in [(inherited, inheritedWithoutBadge), (explicit, withoutBadge)] {
            func changedPixels(in columns: Range<Int>) -> Int {
                columns.reduce(0) { count, x in
                    count + row.filter { y in pixel(withBadge, x: x, y: y) != pixel(plain, x: x, y: y) }.count
                }
            }
            // The badge is between the title and the mark. The title stays in the same place.
            #expect(changedPixels(in: (origins[0] + 65)..<(origins[0] + 118)) > 60)
            #expect(changedPixels(in: (origins[0] + 10)..<(origins[0] + 60)) == 0)
        }
        // The selected mark has ink in the middle of the ring.
        let markX = origins[1] + 132
        let tickPixels = (markX - 4 ... markX + 4).filter { x in
            pixel(explicit, x: x, y: centerY) != full
        }
        #expect(!tickPixels.isEmpty)
        #expect((markX - 4 ... markX + 4).allSatisfy { pixel(inherited, x: $0, y: centerY) == raised })
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func inspectorSelectionMovesBetweenNeutralRows(scheme: ColorScheme) async throws {
        let clay = AppTheme.accentColor(for: "Clay")
        // 300 pt inspector less its two 14 pt body insets. The canvas adds 12 pt on each side.
        let size = NSSize(width: 296, height: 140)
        func render(_ selection: String) async throws -> NSBitmapImageRep {
            let picker = HerdrTemplatePicker(selection: .constant(selection), templates: [claude, codex],
                                             defaultName: claude.name, defaultNote: "Default", inInspector: true)
            return try await snapshot(picker.tint(clay), size: size, scheme: scheme)
        }
        let inherited = try await render("")
        let explicit = try await render(codex.name)
        // Sample the body of each row, between its words and its checkmark.
        let x = 205
        let rows = tileRows(in: inherited, x: x)
        try #require(rows.count == 2)
        #expect(tileRows(in: explicit, x: x) == rows)
        let first = rows[0].lowerBound + rows[0].count / 2
        let second = rows[1].lowerBound + rows[1].count / 2
        #expect(pixel(inherited, x: x, y: first) == pixel(explicit, x: x, y: second))
        #expect(pixel(inherited, x: x, y: second) == pixel(explicit, x: x, y: first))
        let a = try #require(pixel(explicit, x: x, y: first)?.usingColorSpace(.sRGB))
        let b = try #require(pixel(explicit, x: x, y: second)?.usingColorSpace(.sRGB))
        let difference = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        #expect(difference > 0 && difference < 0.35, "Selection should leave a light tint on the neutral control surface")
    }

    @Test func wrappingTitlesAndNotesGrowOnlyTheirOwnRow() async throws {
        let choices = [
            NamedChoice(id: "long", name: "A model with a much longer name", note: "A note that also needs room to wrap"),
            NamedChoice(id: "short", name: "Codex"),
            NamedChoice(id: "next", name: "Gemini"),
        ]
        let gallery = TileGallery(items: choices, isSelected: { $0.id == "short" }, name: \.name, select: { _ in }) {
            NameTile(name: $0.name, note: $0.note)
        }
        let image = try await snapshot(gallery, size: NSSize(width: 296, height: 200), scheme: .dark)
        let firstColumn = tileRows(in: image, x: 72)
        let secondColumn = tileRows(in: image, x: 212)
        try #require(firstColumn.count == 2)
        #expect(secondColumn == [firstColumn[0]])
        #expect(firstColumn[0].count > 42)
        #expect(firstColumn[1].count == 42)
        #expect(firstColumn[1].lowerBound - firstColumn[0].upperBound == 8)
    }

    @Test func selectedBadgeAndMarkHaveReadableInkForEveryAccent() {
        for scheme: ColorScheme in [.light, .dark] {
            let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            appearance?.performAsCurrentDrawingAppearance {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                func rgb(_ color: Color) -> RGB {
                    let resolved = color.resolve(in: environment)
                    return RGB(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
                }
                for accent in AppTheme.accentNames {
                    let fill = AppTheme.accentColor(for: accent)
                    let ink = ChoiceTile<NameTile>.contrastingInk(on: fill, in: environment)
                    #expect(rgb(ink).contrast(with: rgb(fill)) >= 4.5, "\(accent), \(scheme)")
                }
            }
        }
    }

    private static func template(_ name: String, harness: String, display: String) -> HerdrClient.Template {
        .init(name: name, description: nil, error: nil,
              runtime: .init(harness: harness, provider: nil, model: nil, displayName: display))
    }

    private func snapshot(_ view: some View, size: NSSize, scheme: ColorScheme) async throws -> NSBitmapImageRep {
        let canvas = view.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 1, green: 0, blue: 1))
        let png = try #require(await SnapshotRenderer.png(canvas, size: size, scale: 1, scheme: scheme))
        return try #require(NSBitmapImageRep(data: png))
    }

    private func pixel(_ image: NSBitmapImageRep, x: Int, y: Int) -> NSColor? { image.colorAt(x: x, y: y) }

    private func tileRows(in image: NSBitmapImageRep, x: Int) -> [Range<Int>] {
        let background = pixel(image, x: 0, y: 0)
        var rows: [Range<Int>] = []
        var start: Int?
        for y in 0..<image.pixelsHigh {
            if pixel(image, x: x, y: y) != background {
                if start == nil { start = y }
            } else if let lower = start {
                rows.append(lower..<y)
                start = nil
            }
        }
        return rows
    }
}
