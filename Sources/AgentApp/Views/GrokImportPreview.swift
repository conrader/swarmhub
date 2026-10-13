import SwiftUI

/// Preview of a Grok Bot export before import: one row per bot with its mapped avatar, profile and history size.
struct GrokImportPreview: View {
    let bundles: [GrokBotBundle]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(bundles.count) bots from Grok Bot").font(.headline)
                Text("Each bot is bound to its grok-<name> Hermes profile; its key is read from the Keychain when you send. Imported history is read-only and never sent to Hermes.").font(.caption).foregroundStyle(.secondary)
                ForEach(bundles, id: \.sourceId) { bundle in
                    let mapped = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
                    HStack(spacing: 10) {
                        AvatarImage(name: mapped.avatar).frame(width: 30, height: 30).clipShape(Circle())
                            .overlay(Circle().stroke(mapped.accent.flatMap(Color.init(hex:)) ?? AppColor.separator, lineWidth: 1.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bundle.name).fontWeight(.medium)
                            Text((bundle.isGroup ?? false) ? "Archived group · \((bundle.members ?? []).map(\.name).joined(separator: ", "))" : (bundle.profile ?? "no profile")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(bundle.messages.count + bundle.events.count) history").font(.caption).foregroundStyle(.secondary)
                    }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(20)
        }
    }
}
