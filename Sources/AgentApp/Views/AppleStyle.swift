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
    var colour: Color = .blue
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

/// A raised surface for one group of things that belong together.
private struct AppleCard: ViewModifier {
    var padding: CGFloat
    var selected = false
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous).strokeBorder(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.primary.opacity(0.06)), lineWidth: selected ? 2 : 1) }
    }
}

extension View {
    func appleCard(padding: CGFloat = 14, selected: Bool = false) -> some View { modifier(AppleCard(padding: padding, selected: selected)) }
}

/// One of a few large options: a symbol tile, a title and one line. The chosen one is outlined and ticked; a second
/// click (or a double click) can go on at once.
struct OptionCard: View {
    let symbol: String
    var colour: Color = .blue
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
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                        .foregroundStyle(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.tertiary)).accessibilityHidden(true)
                }
            }
            .appleCard(padding: 12, selected: selected).contentShape(RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in open?() })
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(multiple ? (selected ? "On" : "Off") : "")
    }
}

/// One tile of a gallery: whatever the choice looks like, outlined and ticked when it is the chosen one.
struct ChoiceTile<Label: View>: View {
    let selected: Bool
    var name: String? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.12)) : AnyShapeStyle(AppColor.raised), in: RoundedRectangle(cornerRadius: AppleMetrics.tileCorner, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: AppleMetrics.tileCorner, style: .continuous).strokeBorder(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: selected ? 2 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: AppleMetrics.tileCorner, style: .continuous))
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
    var colour: Color = .blue
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol { SymbolTile(symbol: symbol, colour: colour, size: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail, !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(title)
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
        .background(tint.opacity(kind == .working || kind == .info ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: kind)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind { case .working, .info: .primary; case .good: .green; case .warning: .orange }
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .working: ProgressView().controlSize(.small)
        case .good: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green).transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange).transition(.opacity)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).font(.subheadline.weight(.medium))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(isOpen ? Text(verbatim: "open") : Text(verbatim: "folded"))
            if isOpen { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
