import SwiftUI

/// P27: above the manager's composer when its own `swarmhub-manager` skill needs installing or updating.
struct SkillInstallBanner: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let state: SkillInstallState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.secondary)
            Text(AppStore.skillBannerText(bot: bot.name, state: state)).font(.system(size: 12))
            Spacer()
            Button("Not now") { store.snoozeSkillBanner(for: bot) }
            Button(state == .missing ? "Install" : "Update") { store.installSkills(for: bot) }
                .buttonStyle(.borderedProminent).disabled(!store.isIdle)
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
        let skills = store.skills(for: bot)
        if !skills.isEmpty {
            Section("SwarmHub skills") {
                ForEach(skills, id: \.name) { skill in
                    let state = store.skillState(skill, for: bot)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.system(size: 12, weight: .medium))
                            Text(Self.stateText(state, bundled: skill.version)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.manager(for: bot) == nil {
                            Text("Needs a manager bot to install").font(.caption).foregroundStyle(.secondary)
                        } else if state.needsAction {
                            Button(state == .missing ? "Install" : "Update") { store.installSkills(for: bot) }.disabled(!store.isIdle)
                        }
                    }
                }
                Text("Instructions \(AppConstants.name) installs into this bot’s own profile, so it follows them instead of improvising. Hermes itself is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task(id: bot.id) { await store.refreshInstalledSkills(for: bot) }
        }
    }

    static func stateText(_ state: SkillInstallState, bundled: SkillVersion) -> String {
        switch state {
        case .missing: "Not installed · v\(bundled) available"
        case .outdated(let installed): "v\(installed) installed · v\(bundled) available"
        case .current: "v\(bundled) installed"
        }
    }
}
