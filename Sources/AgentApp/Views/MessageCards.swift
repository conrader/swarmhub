import SwiftUI

/// A sub-agent's task as a chat card (`MessagePresentation.delegation`).
struct DelegationCard: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.metadata["status"] == "completed" ? "checkmark.circle.fill" : "person.2.wave.2")
                .foregroundStyle(message.metadata["status"] == "failed" ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.content).font(.callout.weight(.semibold))
                if let detail = message.metadata["detail"], !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                Text(message.metadata["status"]?.capitalized ?? "Running").font(.caption2).foregroundStyle(.tertiary)
                if let child = store.childTask(for: message) { ChildTaskDetailView(bot: child.bot, task: child.task) }
            }
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
}
