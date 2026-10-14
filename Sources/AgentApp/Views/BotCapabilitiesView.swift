import SwiftUI

/// The Skills tab (P33): SwarmHub skills, then the sections fed by the bot's Hermes profile (skills and toolsets).
/// The model section moved to the Model tab and the server-info load to `InfoPanel`. Imported template skills are listed separately with Install (P32, `ImportedSkillViews.swift`); bare skill names without
/// Markdown stay as chips.
struct BotCapabilitiesView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache
    @State private var query = ""

    private var info: BotServerInfo? { cache.info(for: bot.id) }
    private var isHermes: Bool { bot.backend == .hermes && !bot.isReadOnlyArchive }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SwarmHubSkillsPanelSection(bot: bot)
            if isHermes {
                skillsSection
                toolsetsSection
            }
            importedSection
        }
    }

    // MARK: Skills

    @ViewBuilder private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skills").font(.headline)
                if let skills = info?.skills.value { Text("\(skills.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            switch info?.skills ?? .loading {
            case .loading: note("Loading skills…")
            case .unavailable(let reason): note(reason)
            case .failed(let reason): failure(reason)
            case .loaded(let skills):
                if skills.isEmpty { note("No skills are installed on this profile.") }
                else {
                    if skills.count > 12 { TextField("Search skills", text: $query).textFieldStyle(.roundedBorder).controlSize(.small) }
                    let groups = Self.grouped(Self.filtered(skills, query: query))
                    ForEach(groups, id: \.category) { group in
                        if groups.count > 1 || group.category != nil { Text(group.category ?? "Other").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2) }
                        ForEach(group.skills) { skill in row(skill.name, detail: skill.description) }
                    }
                    if groups.isEmpty { note(query.trimmingCharacters(in: .whitespaces).isEmpty ? "No skills to show." : "No skills match “\(query)”.") }
                }
            }
        }
    }

    nonisolated static func filtered(_ skills: [HermesSkill], query: String) -> [HermesSkill] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.description.localizedCaseInsensitiveContains(needle) || ($0.category?.localizedCaseInsensitiveContains(needle) ?? false) }
    }

    /// Groups by category in first-seen order; uncategorised skills come last. Categories whose name starts
    /// with "." (retired/internal, e.g. `.collision-retired`) are hidden with their skills.
    nonisolated static func grouped(_ skills: [HermesSkill]) -> [(category: String?, skills: [HermesSkill])] {
        var order: [String?] = []; var buckets: [String?: [HermesSkill]] = [:]
        for skill in skills where !(skill.category?.hasPrefix(".") ?? false) {
            if buckets[skill.category] == nil { order.append(skill.category) }
            buckets[skill.category, default: []].append(skill)
        }
        order.sort { ($0 == nil ? 1 : 0) < ($1 == nil ? 1 : 0) }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: Toolsets

    @ViewBuilder private var toolsetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(.headline)
                if let toolsets = info?.toolsets.value { Text("\(toolsets.filter { $0.enabled != false }.count) of \(toolsets.count) on").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            switch info?.toolsets ?? .loading {
            case .loading: note("Loading tools…")
            case .unavailable(let reason): note(reason)
            case .failed(let reason): failure(reason)
            case .loaded(let toolsets):
                if toolsets.isEmpty { note("This profile reports no toolsets.") }
                ForEach(toolsets) { toolset in
                    row(toolset.label, detail: toolset.description, badge: toolset.enabled.map { $0 ? (toolset.configured == false ? "Needs setup" : "On") : "Off" })
                        .opacity(toolset.enabled == false ? 0.6 : 1)
                }
            }
        }
    }

    // MARK: Imported

    /// Bare names only: skills with Markdown have their own section with Install.
    private var importedNames: [String] {
        let withMarkdown = Set(store.importedSkills(for: bot).map { $0.name.lowercased() })
        return Self.importedOnly(bot.skills.filter { !withMarkdown.contains($0.lowercased()) }, server: info?.skills.value ?? [])
    }

    /// Local skill names, de-duplicated, minus any the server already lists (case-insensitive).
    nonisolated static func importedOnly(_ local: [String], server: [HermesSkill]) -> [String] {
        let onServer = Set(server.map { $0.name.lowercased() })
        var names: [String] = []
        for name in local where !names.contains(name) && !onServer.contains(name.lowercased()) { names.append(name) }
        return names
    }

    @ViewBuilder private var importedSection: some View {
        ImportedSkillsSection(bot: bot, server: info?.skills.value ?? [])
        let names = importedNames
        if !isHermes && store.importedSkills(for: bot).isEmpty || !names.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(isHermes ? "Other imported names (not on server)" : "Skills").font(.headline)
                if names.isEmpty { note("No skills configured") }
                ForEach(names, id: \.self) { name in Text(name).font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(.primary.opacity(0.06), in: Capsule()) }
            }
        }
    }

    // MARK: Pieces

    private func row(_ title: String, detail: String, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption.weight(.semibold)); Spacer(); if let badge { Text(badge).font(.caption2).foregroundStyle(.secondary) } }
            if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func note(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary) }
    private func failure(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(); Button("Retry") { Task { await store.loadServerInfo(for: bot, force: true) } }.controlSize(.small)
        }
    }
}
