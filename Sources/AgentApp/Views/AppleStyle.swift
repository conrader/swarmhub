import AppKit
import SwiftUI

// The pieces the setup wizard, a bot's Details and settings, and the Herdr parts of Settings are built from. They follow
// Apple's own onboarding and creation screens (Setup Assistant, a new user or contact, the Appearance and accent
// pickers): a field stands on its own, a choice is a gallery of tiles with the chosen one outlined, a decision is a
// few large options, and a setting is a heading, one sentence and its control. Nothing here is a row of a table.

enum AppleMetrics {
    static let corner: CGFloat = 12
    static let tileCorner: CGFloat = 10
    /// Between two groups on a screen, and between the parts of one group.
    static let groupSpacing: CGFloat = 26, partSpacing: CGFloat = 8
    /// The widest a column of fields and options gets in a wide window.
    static let column: CGFloat = 460
}

/// An SF Symbol on a coloured, rounded tile, as System Settings marks its panes.
struct SymbolTile: View {
    let symbol: String
    var colour: Color = AppColor.sky
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(colour.gradient)
            .frame(width: size, height: size)
            .overlay { Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

/// How a screen opens, as in Setup Assistant: a large mark, a large title and one sentence, centred.
struct HeroHeader<Mark: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let mark: () -> Mark

    var body: some View {
        VStack(spacing: 8) {
            mark().padding(.bottom, 6)
            Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: AppleMetrics.column)
            }
        }.frame(maxWidth: .infinity)
    }
}

/// How a chosen thing looks, everywhere in the app: it is filled with the accent and carries a tick. A thing that
/// is not chosen has an outline that can be seen on every surface (3:1). A hairline in the accent alone, which is
/// what marked a choice before, could not be told from the tile beside it on a dark window.
enum Chosen {
    /// How strongly a large card that is chosen is washed with the accent; small tiles are filled with it.
    static let wash = 0.18
    static let line: CGFloat = 2
}

/// The mark of a choice: a filled circle with a tick when chosen, an empty ring when not. `multiple`: a tick box.
struct ChosenMark: View {
    let selected: Bool
    var multiple = false
    var size: CGFloat = 18

    var body: some View {
        let shape = multiple ? AnyInsettableShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)) : AnyInsettableShape(Circle())
        ZStack {
            if selected {
                shape.fill(.tint)
                Image(systemName: "checkmark").font(.system(size: size * 0.56, weight: .bold)).foregroundStyle(AppColor.onAccent)
            } else {
                shape.strokeBorder(AppColor.outline, lineWidth: 1.5)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A circle or a rounded square, as one type.
struct AnyInsettableShape: InsettableShape {
    private let make: @Sendable (CGRect, CGFloat) -> Path
    init<S: InsettableShape>(_ shape: S) { make = { rect, amount in shape.inset(by: amount).path(in: rect) } }
    private var amount: CGFloat = 0
    func path(in rect: CGRect) -> Path { make(rect, amount) }
    func inset(by more: CGFloat) -> AnyInsettableShape { var copy = self; copy.amount += more; return copy }
}

/// A raised surface for one group of things that belong together.
private struct AppleCard: ViewModifier {
    var padding: CGFloat
    var selected = false
    /// One of several to choose from: it is outlined also when it is not the chosen one.
    var choice = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous)
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(TintShapeStyle().opacity(Chosen.wash)) : AnyShapeStyle(.clear), in: shape)
            .background(AppColor.raised, in: shape)
            .overlay { shape.strokeBorder(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(choice ? AppColor.outline : Color.primary.opacity(0.06)), lineWidth: selected ? Chosen.line : 1) }
    }
}

extension View {
    func appleCard(padding: CGFloat = 14, selected: Bool = false, choice: Bool = false) -> some View { modifier(AppleCard(padding: padding, selected: selected, choice: choice)) }
}

/// One of a few large options: a symbol tile, a title and one line. The chosen one is washed with the accent,
/// outlined and ticked; a second click (or a double click) can go on at once.
struct OptionCard: View {
    let symbol: String
    var colour: Color = AppColor.sky
    let title: String
    let detail: String
    var badge: String? = nil
    let selected: Bool
    /// Several of the options can be chosen: the mark is a tick box, not a single choice.
    var multiple = false
    let select: () -> Void
    var open: (() -> Void)? = nil

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 12) {
                SymbolTile(symbol: symbol, colour: colour, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.08)))
                } else {
                    ChosenMark(selected: selected, multiple: multiple, size: 20)
                }
            }
            .appleCard(padding: 12, selected: selected, choice: badge == nil).contentShape(RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in open?() })
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(multiple ? (selected ? "On" : "Off") : "")
    }
}

/// One tile of a gallery: whatever the choice looks like. The chosen one is filled with the accent, its words are
/// written in the colour that reads on it, and it carries a tick; the others are outlined.
struct ChoiceTile<Label: View>: View {
    let selected: Bool
    var name: String? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppleMetrics.tileCorner, style: .continuous)
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                label().frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).accessibilityHidden(true) }
            }
            // `.primary` and `.secondary` inside the label follow this: the tile's own words turn with its fill.
            .foregroundStyle(selected ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(AppColor.raised), in: shape)
            .overlay { if !selected { shape.strokeBorder(AppColor.outline, lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine).accessibilityLabel(name ?? "").accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A choice as a gallery of tiles (the Appearance and accent pickers, not a pop-up menu in a row). A tile's text is
/// never shortened: it wraps, so a model keeps the whole name the server gave it.
struct TileGallery<Item: Identifiable, Label: View>: View {
    let items: [Item]
    var minimum: CGFloat = 132
    let isSelected: (Item) -> Bool
    var name: (Item) -> String = { _ in "" }
    let select: (Item) -> Void
    @ViewBuilder let label: (Item) -> Label

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                ChoiceTile(selected: isSelected(item), name: name(item), action: { select(item) }) { label(item) }
            }
        }
    }
}

/// The usual tile of a gallery of names: the name in full, and a small second line (such as "Default").
struct NameTile: View {
    let name: String
    var note: String? = nil
    var symbol: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// A string as a gallery item.
struct NamedChoice: Identifiable, Equatable {
    let id: String
    let name: String
    var note: String? = nil
}

/// A setting the way Apple lays one out: a heading, one sentence, and the control beneath it. A switch sits beside
/// the heading instead (`SettingSwitch`).
struct SettingBlock<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: AppleMetrics.partSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            control()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch with its heading and its sentence: the heading and sentence on the left, the switch beside them.
struct SettingSwitch: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var colour: Color = AppColor.sky
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol { SymbolTile(symbol: symbol, colour: colour, size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.appleSwitch).accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A field that stands on its own: what it is for above it, the field at full width, and an optional line beneath.
struct StandaloneField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var monospaced = false
    var lines: ClosedRange<Int>? = nil
    var note: String? = nil
    var submit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(title, text: $text, prompt: Text(prompt)) }
                else if let lines { TextField(title, text: $text, prompt: Text(prompt), axis: .vertical).lineLimit(lines) }
                else { TextField(title, text: $text, prompt: Text(prompt)) }
            }
            .labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large).font(monospaced ? .system(.body, design: .monospaced) : .body)
            .onSubmit(submit).accessibilityLabel(title)
            if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// What a check found, or that it is still running: a spinner that becomes a tick or a warning, with its words.
struct StatusCard<Extra: View>: View {
    enum Kind: Equatable { case working, good, warning, info }
    let kind: Kind
    let title: String
    var detail: String? = nil
    @ViewBuilder var extra: () -> Extra
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(kind == .working || kind == .info ? 0.09 : 0.16), in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: kind)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind { case .working, .info: AppColor.olive; case .good: AppColor.sage; case .warning: AppColor.clay }
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .working: ProgressView().controlSize(.small)
        case .good: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(AppColor.good).transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(AppColor.caution).transition(.opacity)
        case .info: Image(systemName: "info.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }
}

extension StatusCard where Extra == EmptyView {
    init(kind: Kind, title: String, detail: String? = nil) { self.init(kind: kind, title: title, detail: detail) { EmptyView() } }
}

/// Text to copy as it is (a command, a key): monospaced, selectable, with a Copy button that says it copied.
struct CopyBox: View {
    let text: String
    var copyLabel = "Copy"
    var copiedLabel = "Copied"
    var lineLimit: Int? = nil
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(lineLimit).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            } label: { Label(copied ? copiedLabel : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc") }
                .controlSize(.small).accessibilityLabel(copyLabel)
        }
        .padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A quiet fold for what few people need: a chevron and a title, the content beneath when open.
struct QuietFold<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).font(.subheadline.weight(.medium))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(isOpen ? Text(verbatim: "open") : Text(verbatim: "folded"))
            if isOpen { content().transition(.opacity) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isOpen)
    }
}

/// An empty place that says what belongs here and what to do, kindly: a soft mark, a title and one sentence.
struct EmptyNote: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var colour: Color = AppColor.sage
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(colour)
                .frame(width: 40, height: 40).background(colour.opacity(0.16), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

/// A caption above a group of related things on a screen that has several.
struct GroupHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small rounded label for one fact about a thing (a difficulty, a state).
struct FactChip: View {
    let text: String
    var symbol: String? = nil
    var colour: Color? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
            Text(text).font(.caption.weight(.medium)).fixedSize()
        }
        .foregroundStyle(colour.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill((colour ?? .primary).opacity(colour == nil ? 0.07 : 0.14)))
    }
}

// MARK: Liquid Glass

/// Liquid Glass, the material macOS 26 gives the layer of controls that floats above content. This is the one place
/// that knows about it: a view asks for `glassSurface`, and gets the material where the Mac has it, and the surface
/// it had before where it has not (the app runs from macOS 14), or where the person asked the system to reduce
/// transparency or to increase contrast. Apple's rule is kept by where it is used, not here: glass is for controls
/// and navigation above content (the message box and the cards on it, the bars, the round buttons), never for the
/// content itself (the words of a chat, message cards, lists), and never on other glass.
enum AppGlass {
    /// Whether the app draws the material when nothing in the window says otherwise (`EnvironmentValues.glassAllowed`).
    /// Not where the app draws itself into a picture: a view with glass in it comes out blank when it is drawn
    /// offscreen (the material is layers the window server composites), so the renders (`--render-setup`,
    /// `--render-snapshot`) and the tests that read pixels show the surfaces of before. `SWARMHUB_NO_GLASS=1` does
    /// the same in the app itself.
    static let byDefault: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["SWARMHUB_NO_GLASS"] == "1" || environment["AGENTAPP_SNAPSHOT"] != nil || TestRunGuard.isTestRun { return false }
        return !CommandLine.arguments.contains { $0 == "--render-setup" || $0 == "--render-snapshot" || $0 == "--agent-qa" }
    }()

    /// The Mac has the material and nothing asks for the plain surface instead.
    static func isOn(allowed: Bool, reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        guard allowed, !reduceTransparency, contrast != .increased else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// How strongly a surface of the app's own colour, or a bot's, tints the glass over it.
    static let surfaceTint = 0.5, botTint = 0.24
}

private struct GlassAllowedKey: EnvironmentKey { static let defaultValue = AppGlass.byDefault }

extension EnvironmentValues {
    /// False draws the surfaces of before in this part of the window, on every Mac.
    var glassAllowed: Bool {
        get { self[GlassAllowedKey.self] }
        set { self[GlassAllowedKey.self] = newValue }
    }
}

/// What the three things that decide about glass say right now, read where a view needs it.
private struct GlassState: DynamicProperty {
    @Environment(\.glassAllowed) private var allowed
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var isOn: Bool { AppGlass.isOn(allowed: allowed, reduceTransparency: reduceTransparency, contrast: contrast) }
    var moreContrast: Bool { contrast == .increased }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    /// The colour the glass leans to (the warm surface of the palette, a bot's colour); nil leaves the system's.
    let tint: Color?
    /// A control that answers the pointer (a button), as the system's glass buttons do.
    let interactive: Bool
    /// What is drawn without the material: the surface, and the line around it.
    let fallback: AnyShapeStyle
    let border: AnyShapeStyle
    private let glass = GlassState()

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), glass.isOn {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(fallback, in: shape).overlay(shape.strokeBorder(border, lineWidth: glass.moreContrast ? 1 : 0.5))
        }
    }
}

private struct GlassGroup: ViewModifier {
    let spacing: CGFloat?
    private let glass = GlassState()

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), glass.isOn {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

/// A shadow for a surface that floats, drawn only without the material: glass brings its own.
private struct PlainSurfaceShadow: ViewModifier {
    private let glass = GlassState()
    func body(content: Content) -> some View {
        if glass.isOn { content } else { content.shadow(color: .black.opacity(0.18), radius: 6, y: 2) }
    }
}

/// Controls at the top or the bottom edge of something that scrolls. With the material they float: what scrolls
/// passes beneath them and softens at that edge, as under the system's own bars (`safeAreaBar`, a soft scroll edge
/// effect). Without it they stand on `backing`, where nothing shows through, exactly as before.
private struct FloatingBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let backing: Color
    @ViewBuilder let bar: () -> Bar
    private let glass = GlassState()

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), glass.isOn {
            content.safeAreaBar(edge: edge, spacing: 0) { bar() }.scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) { bar().background(backing) }
        }
    }
}

extension View {
    /// A surface of the layer of controls: Liquid Glass in `shape` on macOS 26, otherwise `fallback` with `border`.
    func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false,
                                          fallback: some ShapeStyle = AppColor.raised, border: some ShapeStyle = AppColor.separator) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: AnyShapeStyle(fallback), border: AnyShapeStyle(border)))
    }

    /// Controls that float at an edge of this scrolling view where the Mac has the material, and stand on `backing`
    /// where it has not.
    func floatingBar<Bar: View>(edge: VerticalEdge, backing: Color, @ViewBuilder _ bar: @escaping () -> Bar) -> some View {
        modifier(FloatingBar(edge: edge, backing: backing, bar: bar))
    }

    /// The shadow a floating surface had before the material, where it is drawn without it.
    func plainSurfaceShadow() -> some View { modifier(PlainSurfaceShadow()) }

    /// Glass surfaces that stand close together are drawn as one group (`GlassEffectContainer`), which is how the
    /// system renders them together. Neighbours nearer than `spacing` blend into each other: the cards above the
    /// message box stand 8 pt apart and use 4, so they stay separate shapes.
    func glassGroup(spacing: CGFloat? = nil) -> some View { modifier(GlassGroup(spacing: spacing)) }

    /// A card above the composer, as wide as the composer: glass that leans to the bot's own colour; without the
    /// material, a soft wash of that colour on the card surface.
    func chatCard(tint: BotTint) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return padding(.horizontal, 12).padding(.vertical, 10)
            .glassSurface(in: shape, tint: tint.fill.opacity(AppGlass.botTint), fallback: ChatCardFill(tint: tint), border: tint.border)
            .padding(.horizontal, 24).frame(maxWidth: 768)
    }
}

/// The card surface washed with a bot's colour, as one style.
private struct ChatCardFill: ShapeStyle {
    let tint: BotTint
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle { AppColor.card.blendedWash(tint.wash, in: environment) }
}

private extension Color {
    /// This colour with `wash` laid over it, resolved for the scheme at hand.
    func blendedWash(_ wash: Color, in environment: EnvironmentValues) -> Color {
        let base = resolve(in: environment), top = wash.resolve(in: environment), alpha = Double(top.opacity)
        return Color(red: Double(top.red) * alpha + Double(base.red) * (1 - alpha), green: Double(top.green) * alpha + Double(base.green) * (1 - alpha),
                     blue: Double(top.blue) * alpha + Double(base.blue) * (1 - alpha))
    }
}

/// Words that may be long, in a card where something else matters more (its buttons): one line until the person
/// unfolds them. Short words are simply shown.
struct FoldedWords: View {
    let text: String
    var colour: Color = .secondary
    /// What the words are, for VoiceOver and the tooltip: "instructions".
    var name = "text"
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if open || text.contains("\n") { fold }
        else {
            // Words that fit on the card's one line are simply shown; only longer ones get the fold.
            ViewThatFits(in: .horizontal) {
                Text(text).font(.caption).foregroundStyle(colour).lineLimit(1).fixedSize().textSelection(.enabled)
                fold
            }
        }
    }

    private var fold: some View {
        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { open.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(text).font(.caption).foregroundStyle(colour).lineLimit(open ? nil : 1).truncationMode(.tail).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(colour).rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(open ? "Show less" : "Show all of the \(name)")
        .accessibilityLabel(text).accessibilityValue(open ? "Unfolded" : "Folded").accessibilityHint(open ? "Show less" : "Show all of the \(name)")
    }
}

/// A switch drawn by the app, so that "on" can be seen with every accent and in a window that is not in front: the
/// track is filled with the accent and the knob is on the right; off, the track is the outline colour. (The system's
/// switch with the Graphite accent on a dark window is a white knob on a white track.)
struct AppleSwitchStyle: ToggleStyle {
    /// The switch's own words are drawn beside it; most switches in the app have their heading elsewhere.
    var labelled = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let width: CGFloat = small ? 32 : 40, height: CGFloat = small ? 18 : 22
        HStack(spacing: 8) {
            if labelled { configuration.label }
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { configuration.isOn.toggle() } } label: {
                Capsule().fill(configuration.isOn ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(AppColor.outline))
                    .frame(width: width, height: height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? AppColor.onAccent : Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.45)
            // To VoiceOver and the keyboard it is the switch it looks like.
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

extension ToggleStyle where Self == AppleSwitchStyle {
    static var appleSwitch: AppleSwitchStyle { AppleSwitchStyle() }
    /// With the switch's own words beside it.
    static var appleSwitchLabelled: AppleSwitchStyle { AppleSwitchStyle(labelled: true) }
}

/// The default button of a place, drawn by the app: filled with the accent, its label in the colour that reads on
/// it (4.5:1 with Clay, Sage and Graphite, light and dark). The system's prominent button writes white on every
/// accent, which on Graphite in a dark window is white on white, and it turns grey in a window that is not in front.
struct AppleProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics: (font: CGFloat, pad: CGFloat, height: CGFloat, corner: CGFloat) = switch controlSize {
        // As tall as the system's own buttons of each size, so the two stand level in one row.
        case .mini, .small: (11, 8, 17, 5)
        case .large, .extraLarge: (13, 16, 28, 7)
        default: (13, 11, 20, 6)
        }
        configuration.label.font(.system(size: metrics.font, weight: .semibold)).foregroundStyle(AppColor.onAccent).lineLimit(1)
            .padding(.horizontal, metrics.pad).frame(minHeight: metrics.height)
            .background(TintShapeStyle(), in: RoundedRectangle(cornerRadius: metrics.corner, style: .continuous))
            .overlay { if configuration.isPressed { RoundedRectangle(cornerRadius: metrics.corner, style: .continuous).fill(Color.black.opacity(0.14)) } }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous))
    }
}

extension ButtonStyle where Self == AppleProminentButtonStyle {
    static var appleProminent: AppleProminentButtonStyle { AppleProminentButtonStyle() }
}

/// A choice between a few words in a row, drawn by the app: the chosen one is filled with the accent and ticked.
/// (The system's segmented control draws both halves the same grey in a window that is not in front.)
struct SegmentedChoice<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, name: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 4) {
                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).accessibilityHidden(true) }
                        Text(option.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 22)
                    .background(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(option.name).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppColor.outline, lineWidth: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
