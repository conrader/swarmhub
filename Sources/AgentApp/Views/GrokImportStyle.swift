import SwiftUI

/// The shared pieces of the import sheet, so every step reads the same way: one card surface, one notice, one
/// numbered step, and the large card a choice is made with.
extension View {
    /// The sheet's one raised surface: rows, notices and grouped text all sit on it.
    func grokCard(padding: CGFloat = 10) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One thing the user should know now: a symbol and a sentence or two on the card surface.
struct GrokNotice: View {
    enum Tone { case info, caution }

    let text: String
    var symbol = "info.circle"
    var tone = Tone.info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tone == .caution ? AppColor.caution : Color.secondary)
                .accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .grokCard()
        .accessibilityElement(children: .combine)
    }
}

/// One of two or three exclusive choices, large enough to be the first thing seen on its step: a radio mark, a title,
/// one sentence and a short footnote. The chosen card carries the accent on its mark and its edge.
struct GrokChoiceCard: View {
    let title: String
    let detail: String
    var footnote: String?
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : AppColor.outline)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : AppColor.outline.opacity(0.35), lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .accessibilityLabel([title, detail, footnote].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(enabled ? "One of two choices" : "Not available")
    }
}

/// One numbered step of a short instruction: the number in a tinted disc, what to do, and one sentence about it.
struct GrokNumberedStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.callout.weight(.semibold).monospacedDigit()).frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.2), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title) \(detail)")
    }
}

/// A small capsule tag beside a name ("group", "hidden in Grok").
struct GrokTag: View {
    let text: String

    var body: some View {
        Text(text).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.08), in: Capsule())
    }
}
