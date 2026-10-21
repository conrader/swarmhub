import SwiftUI

/// P42 7: the one confirmation for installing the messaging skills on every bot of a connection: which bots and what
/// each is missing, then one management turn.
struct AllBotsSkillConfirmation: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Binding var manager: Bot?
    func body(content: Content) -> some View {
        let gaps = (manager.map { store.messagingSkillGaps(manager: $0) } ?? []).filter { !$0.installable.isEmpty }
        content.confirmationDialog(AllBotsSkillCopy.button + "?", isPresented: Binding(get: { manager != nil }, set: { if !$0 { manager = nil } })) {
            Button(gaps.count == 1 ? "Install on 1 bot" : "Install on \(gaps.count) bots") { if let manager { store.installSkillsOnAllBots(manager: manager) }; manager = nil }
            Button("Cancel", role: .cancel) { manager = nil }
        } message: {
            Text(gaps.map { "\($0.bot.name): \($0.installable.map(\.name).joined(separator: ", "))" }.joined(separator: "\n") + "\n\n" + AllBotsSkillCopy.confirm)
        }
    }
}

/// Each bot of a connection and the messaging skills it is missing; a failed install also says why and when to retry.
struct SkillGapRows: View {
    @EnvironmentObject private var store: AppStore
    let gaps: [AppStore.SkillGap]
    var body: some View {
        ForEach(gaps) { gap in
            SkillRetryRefresh(dates: store.skillRetryDates(gap.skills, for: gap.bot)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        BotAvatar(bot: gap.bot, size: 18)
                        Text(gap.bot.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(AllBotsSkillCopy.missing(gap.skills)).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(gap.skills, id: \.name) { skill in
                        if let failure = store.skillInstallFailure(skill, for: gap.bot) {
                            Text(store.skillFailureText(failure, skill: skill)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}

/// Bots whose messaging-skill install failed and waits out its backoff: which skills, and when it may be retried.
struct SkillWaitRows: View {
    let waits: [AppStore.SkillWait]
    var body: some View {
        ForEach(waits) { wait in
            HStack(spacing: 8) {
                BotAvatar(bot: wait.bot, size: 18)
                Text(wait.bot.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(AllBotsSkillCopy.waiting(wait.skills, retryAt: wait.retryAt)).font(.caption).foregroundStyle(.orange)
            }
            .help(wait.reason)
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
            if let summary = store.allBotsSkillsSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            SkillWaitRows(waits: store.messagingSkillWaits())
            ForEach(managers) { manager in
                SkillGapRows(gaps: store.messagingSkillGaps(manager: manager))
                SkillRetryRefresh(dates: store.messagingRetryDates(manager: manager)) {
                    HStack {
                        Button(AllBotsSkillCopy.button) { confirming = manager }.disabled(!store.canInstallSkillsOnAllBots(manager: manager))
                        Text("through \(manager.name)").font(.caption).foregroundStyle(.secondary)
                    }
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
        SkillRetryRefresh(dates: store.messagingRetryDates(manager: manager)) { banner }
    }

    @ViewBuilder private var banner: some View {
        let gaps = store.messagingSkillGaps(manager: manager)
        if !gaps.isEmpty && !hidden {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AllBotsSkillCopy.banner(gaps.count)).font(.system(size: 12))
                    Text(gaps.map(\.bot.name).joined(separator: ", ") + (AllBotsSkillCopy.retry(gaps.contains { !$0.installable.isEmpty } ? nil
                         : store.messagingRetryDates(manager: manager).first) ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Not now") { hidden = true }
                Button(AllBotsSkillCopy.button) { confirming = manager }.buttonStyle(.borderedProminent).disabled(!store.canInstallSkillsOnAllBots(manager: manager))
            }
            .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 9)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppColor.separator, lineWidth: 0.5))
            .padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 720)
            .modifier(AllBotsSkillConfirmation(manager: $confirming))
        }
    }
}

/// P45 6: over a 1:1 composer when "@Bot …" needs the messaging skill the open bot lacks: install it on every bot first.
struct MentionSkillOffer: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var confirming: Bot?
    var body: some View {
        SkillRetryRefresh(dates: store.manager(for: bot).map { store.messagingRetryDates(manager: $0) } ?? []) { offer }
    }

    private var offer: some View {
        let manager = store.manager(for: bot)
        return HStack(spacing: 10) {
            Image(systemName: "at").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(bot.name) can't message other bots yet: it needs the swarmhub-messages skill.").font(.system(size: 12))
                Text(manager == nil ? AllBotsSkillCopy.needsManager : "Your message stays in the box until it is installed.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Not now") { store.mentionSkillOffer = nil }
            if let manager { Button(AllBotsSkillCopy.button) { confirming = manager }.buttonStyle(.borderedProminent).disabled(!store.canInstallSkillsOnAllBots(manager: manager)) }
        }
        .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 9)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 720)
        .modifier(AllBotsSkillConfirmation(manager: $confirming))
        .accessibilityIdentifier("chat.mentionSkillOffer")
    }
}
