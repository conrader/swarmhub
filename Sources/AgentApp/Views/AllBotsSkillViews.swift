import SwiftUI

/// P42 7: the one confirmation for installing the messaging skills on every bot of a connection: which bots and what
/// each is missing, then one management turn.
private struct AllBotsSkillConfirmation: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Binding var manager: Bot?
    func body(content: Content) -> some View {
        let gaps = manager.map { store.messagingSkillGaps(manager: $0) } ?? []
        content.confirmationDialog(AllBotsSkillCopy.button + "?", isPresented: Binding(get: { manager != nil }, set: { if !$0 { manager = nil } })) {
            Button(gaps.count == 1 ? "Install on 1 bot" : "Install on \(gaps.count) bots") { if let manager { store.installSkillsOnAllBots(manager: manager) }; manager = nil }
            Button("Cancel", role: .cancel) { manager = nil }
        } message: {
            Text(gaps.map { "\($0.bot.name): \($0.skills.map(\.name).joined(separator: ", "))" }.joined(separator: "\n") + "\n\n" + AllBotsSkillCopy.confirm)
        }
    }
}

/// Each bot of a connection and the messaging skills it is missing.
struct SkillGapRows: View {
    let gaps: [AppStore.SkillGap]
    var body: some View {
        ForEach(gaps) { gap in
            HStack(spacing: 8) {
                BotAvatar(bot: gap.bot, size: 18)
                Text(gap.bot.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(AllBotsSkillCopy.missing(gap.skills)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings → Servers and keys: per connection, the bots missing the messaging skills and the install button.
struct AllBotsSkillsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirming: Bot?
    var body: some View {
        Section(AllBotsSkillCopy.title) {
            let managers = store.managersWithSkillGaps
            if managers.isEmpty {
                let unmanaged = store.bots.contains { $0.backend == .hermes && store.manager(for: $0) == nil && !store.missingMessagingSkills(for: $0).isEmpty }
                Text(unmanaged ? AllBotsSkillCopy.needsManager : AllBotsSkillCopy.allSet).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(managers) { manager in
                SkillGapRows(gaps: store.messagingSkillGaps(manager: manager))
                HStack {
                    Button(AllBotsSkillCopy.button) { confirming = manager }.disabled(!store.isIdle(manager))
                    Text("through \(manager.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.modifier(AllBotsSkillConfirmation(manager: $confirming))
    }
}

/// Above the manager's composer while bots on its connection lack the messaging skills.
struct AllBotsSkillsBanner: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: Bot
    @State private var confirming: Bot?
    @State private var hidden = false
    var body: some View {
        let gaps = store.messagingSkillGaps(manager: manager)
        if !gaps.isEmpty && !hidden {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AllBotsSkillCopy.banner(gaps.count)).font(.system(size: 12))
                    Text(gaps.map(\.bot.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Not now") { hidden = true }
                Button(AllBotsSkillCopy.button) { confirming = manager }.buttonStyle(.borderedProminent).disabled(!store.isIdle(manager))
            }
            .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 9)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 720)
            .modifier(AllBotsSkillConfirmation(manager: $confirming))
        }
    }
}
