import SwiftUI

/// P32: Overview → "Imported skills": the template's skills (and its getting-started skill) with their state on this
/// agent's box and "Install on <bot>…", which opens the SKILL.md first. Install goes through the connection's manager.
struct ImportedSkillsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    /// Skills the box lists, when it answered.
    let server: [HermesSkill]
    @State private var reading: ImportedTemplateSkill?

    var body: some View {
        let skills = store.importedSkills(for: bot)
        if !skills.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Imported skills").font(.headline)
                ForEach(skills) { skill in
                    let installed = Self.isInstalled(skill, server: server)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.caption.weight(.semibold))
                            Text(Self.stateText(skill, installed: installed)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.canInstallImported(on: bot) {
                            Button(installed ? "Reinstall…" : "Install on \(bot.name)…") { reading = skill }.controlSize(.small).disabled(!store.isIdle)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(Self.footnote(canInstall: store.canInstallImported(on: bot), hermes: bot.backend == .hermes)).font(.caption).foregroundStyle(.secondary)
            }
            .sheet(item: $reading) { skill in ImportedSkillInstallSheet(bot: bot, skill: skill) }
        }
    }

    /// Installed when SwarmHub recorded the manager's `skills_installed` row or the box lists its folder name.
    nonisolated static func isInstalled(_ skill: ImportedTemplateSkill, server: [HermesSkill]) -> Bool {
        guard !skill.isEnabled else { return true }
        guard let folder = AppStore.importedSkillFolder(skill.name) else { return false }
        return server.contains { $0.name.lowercased() == folder }
    }

    nonisolated static func stateText(_ skill: ImportedTemplateSkill, installed: Bool) -> String {
        let kind = skill.isGettingStarted ? "Getting started" : "From the template"
        return "\(kind) · " + (installed ? "installed on this agent" : "not installed yet")
    }

    nonisolated static func footnote(canInstall: Bool, hermes: Bool) -> String {
        guard hermes else { return "Kept with this agent in \(AppConstants.name); installing needs a Hermes agent." }
        return canInstall
            ? "Install shows the skill first; this agent’s manager bot then writes it into its profile. Hermes itself is not changed."
            : "Kept with this agent in \(AppConstants.name). Installing needs a manager bot on this agent’s server."
    }
}

/// The imported skill's SKILL.md as it will be written, and Install. Pressing Install is the confirmation.
struct ImportedSkillInstallSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bot: Bot
    let skill: ImportedTemplateSkill

    var body: some View {
        let file = AppStore.importedSkillFile(skill, botName: bot.name)
        let managerName = store.manager(for: bot)?.name ?? "the manager bot"
        VStack(alignment: .leading, spacing: 12) {
            Text("Install “\(skill.name)” on \(bot.name)?").font(.title3.weight(.semibold))
            Text(Self.explanation(skill: skill, bot: bot.name, manager: managerName)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let file {
                ScrollView {
                    Text(file).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColor.separator, lineWidth: 0.5))
            } else {
                Text("This skill’s name has no letters or digits to use as a folder name, so it cannot be installed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { if store.installImportedSkill(skill, on: bot) { dismiss() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(file == nil || !store.isIdle || !store.canInstallImported(on: bot))
            }
        }
        .padding(20).frame(width: 560, height: 520)
    }

    nonisolated static func explanation(skill: ImportedTemplateSkill, bot: String, manager: String) -> String {
        let folder = AppStore.importedSkillFolder(skill.name) ?? "…"
        return "This skill came with the template, so read it before installing. \(manager) writes it into \(bot)’s profile as "
            + "skills/\(AppStore.importedCategory)/\(folder)/SKILL.md, in one turn in its chat. Hermes itself is not changed."
    }
}
