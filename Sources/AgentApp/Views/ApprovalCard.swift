import SwiftUI

struct ApprovalCard: View {
    @EnvironmentObject private var store: AppStore
    let request: ApprovalRequest; let decide: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Approval required").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let reviewer = request.reviewerID.flatMap({ id in store.bots.first { $0.id == id } }) { BotAvatar(bot: reviewer, size: 16); Text(reviewer.name).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(request.title).font(.system(size: 14, weight: .semibold)); Text(request.summary).font(.system(size: 13)).foregroundStyle(.secondary)
            if !request.hasKnownCommand { Text("Command unknown — approval is disabled.").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange) }
            if let rule = request.rule { Label(rule, systemImage: "list.bullet.rectangle").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            if let note = request.routeNote { Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            if let draft = request.draft { Text(draft).font(.system(size: 12, design: .monospaced)).padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)) }
            HStack { Button("Decline") { decide(false) }.buttonStyle(.plain).foregroundStyle(.secondary); Spacer(); Button("Approve") { decide(true) }.buttonStyle(NeutralPrimaryButtonStyle()).disabled(!request.hasKnownCommand) }
        }.padding(14).frame(maxWidth: 520, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5)).padding(.horizontal, 28).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    }
}
