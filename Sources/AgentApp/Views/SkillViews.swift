import SwiftUI

/// P27: above the manager's composer when its own `swarmhub-manager` skill needs installing or updating.
struct SkillInstallBanner: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let skill: BundledSkill
    let state: SkillInstallState

    var body: some View {
        SkillRetryRefresh(dates: store.skillRetryDates([skill], for: bot)) { banner }
    }

    private var banner: some View {
        let failure = store.skillInstallFailure(skill, for: bot)
        return HStack(spacing: 10) {
            Image(systemName: failure == nil ? "square.and.arrow.down.on.square" : "exclamationmark.triangle")
                .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
            Text(failure.map { store.skillFailureText($0, skill: skill) } ?? AppStore.skillBannerText(bot: bot.name, state: state)).font(.system(size: 12))
            Spacer()
            Button("Not now") { store.snoozeSkillBanner(for: bot) }
            Button(failure != nil ? "Retry" : state == .missing ? "Install" : "Update") { store.installSkills(for: bot) }
                .buttonStyle(.borderedProminent).disabled(!store.managerIdle(for: bot) || store.skillInstallBackingOff(skill, for: bot))
        }
        .controlSize(.small).padding(.horizontal, 14).padding(.vertical, 9)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 28).padding(.top, 8).frame(maxWidth: 720)
    }
}

/// P27: bot editor → Advanced → "SwarmHub skills": each bundled skill meant for this bot, its version and state, and
/// Install/Update through the connection's manager. Opening it confirms the record from `GET /v1/skills` when that works.
struct SwarmHubSkillsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        if !store.skills(for: bot).isEmpty {
            Section("SwarmHub skills") { SwarmHubSkillRows(bot: bot) }
            // Like the capabilities read: only in the real app, never from previews or offscreen renders.
            .task(id: bot.id) { if store.botInfo.autoLoad { await store.refreshInstalledSkills(for: bot) } }
        }
    }

    static func stateText(_ state: SkillInstallState, bundled: SkillVersion) -> String {
        switch state {
        case .missing: "Not installed · v\(bundled) available"
        case .outdated(let installed): "v\(installed) installed · v\(bundled) available"
        case .changed(let installed): "v\(installed) installed · coding agent changed, needs updating"
        case .current: "v\(bundled) installed"
        }
    }
}

/// P33: the same rows at the top of the panel's Skills tab, with the banner's "needs installing/updating" line.
struct SwarmHubSkillsPanelSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        if !store.skills(for: bot).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SwarmHub skills").font(.headline)
                if let banner = store.skillBanner(for: bot) {
                    SkillRetryRefresh(dates: store.skillRetryDates([banner.skill], for: bot)) {
                        Text(store.skillInstallFailure(banner.skill, for: bot).map { store.skillFailureText($0, skill: banner.skill) }
                             ?? AppStore.skillBannerText(bot: bot.name, state: banner.state)).font(.caption).foregroundStyle(.orange)
                    }
                }
                SwarmHubSkillRows(bot: bot)
            }
            .task(id: bot.id) { if store.botInfo.autoLoad { await store.refreshInstalledSkills(for: bot) } }
        }
    }
}

/// Each bundled skill meant for this bot, its version and state, and Install/Update through the connection's manager.
struct SwarmHubSkillRows: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        ForEach(store.skills(for: bot), id: \.name) { skill in
            SkillRetryRefresh(dates: store.skillRetryDates([skill], for: bot)) { row(skill) }
        }
        Text("Instructions \(AppConstants.name) installs into this bot’s own profile, so it follows them instead of improvising. Hermes itself is not changed.")
            .font(.caption).foregroundStyle(.secondary)
        if store.usesStagedSkills(on: store.connection(of: bot)) {
            BoxUpdateView(bot: bot)
        }
    }

    private func row(_ skill: BundledSkill) -> some View {
        let state = store.skillState(skill, for: bot)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.system(size: 12, weight: .medium))
                Text(SwarmHubSkillsSection.stateText(state, bundled: skill.version)).font(.caption).foregroundStyle(.secondary)
                if state.needsAction, let failure = store.skillInstallFailure(skill, for: bot) {
                    Text(store.skillFailureText(failure, skill: skill)).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if store.manager(for: bot) == nil {
                Text("Needs a manager bot to install").font(.caption).foregroundStyle(.secondary)
            } else if state.needsAction {
                let failed = store.skillInstallFailure(skill, for: bot) != nil
                Button(failed ? "Retry" : state == .missing ? "Install" : "Update") { store.installSkills(for: bot) }
                    .disabled(!store.managerIdle(for: bot) || store.skillInstallBackingOff(skill, for: bot))
            }
        }
    }
}

/// Redraws `content` when a failed install's backoff ends (`dates`), so an idle view offers Retry again on time: the
/// backoff is read from the clock while rendering, and nothing else changes at that moment. A task sleeps until each
/// date and then bumps `tick`, which the body reads.
struct SkillRetryRefresh<Content: View>: View {
    let dates: [Date]
    @ViewBuilder let content: () -> Content
    @State private var tick = 0

    var body: some View {
        let _ = tick
        content().task(id: dates) {
            for date in dates {
                let wait = date.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                tick &+= 1
            }
        }
    }
}
