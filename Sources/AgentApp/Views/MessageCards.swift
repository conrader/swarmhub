import SwiftUI

/// Fixed-presentation cards (demo data, sub-agent and routine results) keyed by `MessagePresentation`.
struct DelegationCard: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.metadata["status"] == "completed" ? "checkmark.circle.fill" : "person.2.wave.2")
                .foregroundStyle(message.metadata["status"] == "failed" ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content).font(.callout.weight(.semibold))
                if let detail = message.metadata["detail"], !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                Text(message.metadata["status"]?.capitalized ?? "Running").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
}

struct VoiceMemoCard: View { let message: ChatMessage; @State private var playing = false; var body: some View { HStack(spacing: 12) { Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 28, height: 28).background(.primary, in: Circle()).foregroundStyle(AppColor.chat) }.buttonStyle(.plain); HStack(spacing: 3) { ForEach(0..<18, id: \.self) { index in Capsule().fill(.secondary.opacity(0.55)).frame(width: 2, height: CGFloat(5 + (index * 7) % 17)) } }; Text(message.metadata["duration"] ?? "0:00").font(.caption).foregroundStyle(.secondary) }.padding(10).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 16)) } }
struct LegacyLinkPills: View { let message: ChatMessage; var body: some View { HStack { ForEach((message.metadata["links"] ?? "").components(separatedBy: "|"), id: \.self) { label in Button { } label: { Label(label, systemImage: "link").font(.caption) }.buttonStyle(.bordered) } } } }
struct ImageCard: View { let message: ChatMessage; var body: some View { RoundedRectangle(cornerRadius: 12).fill(AppColor.raised).frame(width: 320, height: 190).overlay(VStack { Image(systemName: "photo").font(.largeTitle); Text(message.metadata["name"] ?? "Image").font(.caption) }.foregroundStyle(.secondary)).overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.separator, lineWidth: 0.5)) } }

struct DraftEmailCard: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Email draft (preview only)").font(.callout.weight(.semibold)).padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("To") { Text(message.metadata["to"] ?? "") }; LabeledContent("Subject") { Text(message.metadata["subject"] ?? "").fontWeight(.medium) }
                Divider(); Text(message.metadata["body"] ?? "").font(.caption).lineSpacing(2).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }.font(.caption).padding(12)
            Divider(); HStack { Text("Sending is not implemented.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Send (stub)") { }.buttonStyle(NeutralPrimaryButtonStyle()).disabled(true) }.padding(10)
        }.frame(maxWidth: 500).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
}

struct OptionCard: View {
    let message: ChatMessage; @State private var selected: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(message.content).font(.callout.weight(.semibold)); FlowButtons(options: (message.metadata["options"] ?? "").components(separatedBy: "|"), selected: $selected)
        }.padding(14).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
}

struct FlowButtons: View {
    let options: [String]; @Binding var selected: String?
    var body: some View {
        HStack {
            ForEach(options, id: \.self) { option in
                Button(option) { selected = option }
                    .buttonStyle(.bordered)
                    .tint(selected == option ? .primary : .secondary)
            }
        }
    }
}

struct AttachmentCard: View {
    let message: ChatMessage
    var body: some View { HStack { Image(systemName: "doc").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(message.metadata["name"] ?? "Attachment").fontWeight(.medium); Text(message.metadata["size"] ?? "File").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.down.circle") }.padding(12).frame(maxWidth: 380).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5)) }
}
