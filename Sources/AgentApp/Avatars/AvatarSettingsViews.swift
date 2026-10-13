import SwiftUI

/// Settings → Appearance → Avatar motion.
struct AvatarMotionSettingRow: View {
    @ObservedObject private var settings = AvatarMotionSettings.shared
    var body: some View {
        Section("Avatars") {
            Picker("Avatar motion", selection: $settings.preference) {
                ForEach(AvatarMotionPreference.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(settings.preference.caption + (settings.preference == .off ? "" : " A working bot hops until its reply ends.") + " macOS Reduce Motion always wins: nothing moves and a dot shows while a bot works.")
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

/// The editor's avatar picker: 16 shapes drawn as still marks in the chosen colour, the 11 swatches below (black shows
/// white in dark), and a collapsed Classic row with the 12 faces and 9 clay avatars.
struct AvatarPickerView: View {
    @Binding var choice: AvatarChoice
    @State private var showClassic = false
    @Environment(\.colorScheme) private var colorScheme

    private var shape: String? { if case .mark(let shape, _) = choice { shape } else { nil } }
    private var colour: AvatarColour? { if case .mark(_, let colour) = choice { colour.flatMap(AvatarColour.init(rawValue:)) } else { nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                ForEach(AvatarKitMap.pickerShapes, id: \.self) { word in
                    Button { choice = .mark(shape: word, colour: colour?.rawValue) } label: {
                        AvatarMarkView(shape: word, colour: colour ?? .gray, size: 32, mode: .still, seed: word).frame(width: 40, height: 40)
                            .background(shape == word ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(word.capitalized + (AvatarKitMap.body(for: word).approximate ? " (approximate)" : ""))
                }
            }
            HStack(spacing: 6) {
                ForEach(AvatarColour.allCases, id: \.self) { swatch in
                    Button { choice = .mark(shape: shape, colour: swatch.rawValue) } label: {
                        Circle().fill(Color(hex: swatch.hex(dark: colorScheme == .dark)) ?? .gray).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(colour == swatch ? 0.9 : 0.15), lineWidth: colour == swatch ? 2 : 0.5).padding(-2))
                    }.buttonStyle(.plain).help(swatch.rawValue.capitalized)
                }
            }
            DisclosureGroup("Classic", isExpanded: $showClassic) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 11), alignment: .leading, spacing: 6) {
                    ForEach(BotAvatarName.allCases) { name in
                        Button { choice = .classic(name) } label: {
                            AvatarImage(name: name).scaledToFill().frame(width: 28, height: 28).clipShape(Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(choice == .classic(name) ? 0.9 : 0), lineWidth: 2).padding(-2))
                        }.buttonStyle(.plain).help(name.displayName)
                    }
                }.padding(.top, 4)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if case .classic = choice { showClassic = true } }
    }

    private var caption: String {
        switch choice {
        case .unpicked: "No pick: the bot gets its own shape and colour from its id, as Grok does."
        case .mark(let shape, let colour): "\(shape ?? "derived shape") / \(colour ?? "derived colour")" + (shape.map { AvatarKitMap.body(for: $0).approximate } == true ? " · drawn approximately" : "")
        case .classic(let name): "Classic: \(name.displayName)"
        }
    }
}
