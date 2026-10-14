import SwiftUI
@preconcurrency import BotAvatarsKit

/// Settings → Appearance → Avatar motion.
struct AvatarMotionSettingRow: View {
    @ObservedObject private var settings = AvatarMotionSettings.shared
    var body: some View {
        Section("Avatars") {
            Picker("Avatar motion", selection: $settings.preference) {
                ForEach(AvatarMotionPreference.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(settings.preference.caption + " macOS Reduce Motion freezes avatars and shows a dot while a bot works.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What the editor holds for the avatar until Save: nothing picked yet (a new bot gets its derived look), a mark
/// (a shape and/or colour word; a missing one is derived at save), or a classic avatar.
enum AvatarChoice: Equatable {
    case unpicked
    case mark(shape: String?, colour: String?)
    case classic(BotAvatarName)

    init(bot: Bot) {
        if let mark = bot.avatarMark { self = .mark(shape: mark.shape, colour: mark.colour) } else { self = .classic(bot.avatarName) }
    }

    func previewMark(seed: String) -> AvatarMark {
        if case .mark(let shape, let colour) = self { return AvatarLook.effectiveMark(shape: shape, colour: colour, seed: seed) }
        return GrokDefaultLook.mark(for: seed)
    }

    mutating func selectShape(_ shape: String, seed: String) {
        self = .mark(shape: shape, colour: previewMark(seed: seed).colour)
    }

    mutating func selectColour(_ colour: AvatarColour, seed: String) {
        self = .mark(shape: previewMark(seed: seed).shape, colour: colour.rawValue)
    }

    /// Applies the choice to a bot: a mark is stored with each missing or invalid field derived from the bot's seed;
    /// a classic pick writes `avatarName` and clears the mark.
    func apply(to bot: Bot) {
        switch self {
        case .unpicked: return
        case .mark(let shape, let colour):
            bot.avatarMark = AvatarLook.effectiveMark(shape: shape, colour: colour, seed: bot.avatarSeed); bot.avatarMarkMigrated = false
        case .classic(let name):
            bot.avatarName = name; bot.avatarMark = nil; bot.avatarMarkMigrated = false
        }
    }
}

/// Native shapes, one tile per body, with immediate preview and explicit selection. Legacy choices remain readable.
struct AvatarPickerView: View {
    @Binding var choice: AvatarChoice
    let seed: String
    @Environment(\.colorScheme) private var colorScheme

    private var mark: AvatarMark { choice.previewMark(seed: seed) }
    private var colour: AvatarColour { AvatarColour(rawValue: mark.colour) ?? .gray }
    private var selectedBody: BotAvatarType? {
        if case .classic = choice { return nil }
        return AvatarKitMap.body(for: mark.shape).type
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Group {
                    if case .classic = choice {
                        Image(systemName: "person.crop.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                    } else {
                        AvatarMarkView(shape: mark.shape, colour: colour, size: 56, mode: .still, seed: seed)
                    }
                }.frame(width: 64, height: 64).accessibilityIdentifier("avatar-preview")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Avatar preview").font(.subheadline.weight(.medium))
                    if let selectedBody {
                        Text("\(selectedBody.preset.label) · \(colour.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Choose a shape and color, then Save.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Shape").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(60), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                ForEach(AvatarKitMap.pickerShapes, id: \.self) { word in
                    let body = AvatarKitMap.body(for: word).type
                    let selected = selectedBody == body
                    Button { choice.selectShape(word, seed: seed) } label: {
                        VStack(spacing: 3) {
                            AvatarMarkView(shape: word, colour: colour, size: 32, mode: .still, seed: seed).frame(width: 40, height: 42)
                            Text(body.preset.label).font(.system(size: 10)).lineLimit(1)
                        }
                        .frame(width: 60, height: 68)
                        .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                        .overlay(alignment: .topTrailing) {
                            if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor).padding(3) }
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(body.preset.label)
                        .accessibilityLabel(body.preset.label).accessibilityValue(selected ? "Selected" : "")
                        .accessibilityIdentifier("avatar-shape-\(word)")
                }
            }
            Text("Color").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(AvatarColour.allCases, id: \.self) { swatch in
                    Button { choice.selectColour(swatch, seed: seed) } label: {
                        Circle().fill(Color(hex: swatch.hex(dark: colorScheme == .dark)) ?? .gray).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: colour == swatch && selectedBody != nil ? 2 : 0).padding(-3))
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(swatch.rawValue.capitalized)
                        .accessibilityLabel(swatch.rawValue.capitalized).accessibilityValue(colour == swatch && selectedBody != nil ? "Selected" : "")
                        .accessibilityIdentifier("avatar-color-\(swatch.rawValue)")
                }
            }
        }
    }
}
