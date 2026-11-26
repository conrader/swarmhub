import SwiftUI

struct InspectorTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(AppColor.separator, lineWidth: 1) }
            .help(text).accessibilityLabel(text)
    }
}

struct InspectorSharedSkills: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    @State private var library: HerdrSkillLibrary?
    @State private var error: String?
    @State private var expanded = false
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shared skills").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Manage") { store.openInfoTab(.skills) }
                    .buttonStyle(.link).accessibilityLabel("Manage shared skills")
            }
            Text(server.name + " library").font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { attempt += 1 }.buttonStyle(.link).accessibilityLabel("Reload shared skills")
            } else if let library {
                if let problem = library.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                if library.installed {
                    tags(library)
                } else if library.problem == nil {
                    Text(HerdrLibraryCopy.notInstalled).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Checking shared skills…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: attempt) {
            guard store.launchWorkEnabled else { return }
            error = nil
            do {
                // This summary reads the server library without running a sync or opening a project library.
                let result = try await store.herdrClient(for: server).skillLibrary()
                if !Task.isCancelled { library = result }
            } catch {
                if !Task.isCancelled { self.error = HerdrSkillsCopy.reason(error) }
            }
        }
    }

    @ViewBuilder private func tags(_ library: HerdrSkillLibrary) -> some View {
        let skills = library.skills.filter(\.enabled)
        if skills.isEmpty && library.hiddenCount == 0 && library.problem == nil {
            Text("No enabled skills").font(.caption).foregroundStyle(.secondary)
        }
        LibraryFlow(spacing: 5) {
            ForEach(skills.prefix(expanded ? skills.count : 6)) { skill in
                InspectorTag(text: skill.name)
            }
        }
        if skills.count > 6 {
            Button(expanded ? "Show fewer skills" : "Show \(skills.count - 6) more") { expanded.toggle() }
                .buttonStyle(.link)
        }
        if library.hiddenCount > 0 {
            Text(HerdrSkillsCopy.more(library.hiddenCount)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
