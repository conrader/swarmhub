import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareLink = ""
    @State private var plan: TemplateImportPlan?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var choosingFile = false
    @State private var isImporting = false
    @State private var grokBundles: [GrokBotBundle]?
    @State private var choosingExport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan == nil ? "Import Grok Bot template" : "Review template import").font(.title2.bold())
                    Text(plan == nil ? "Use a share link that returns export JSON, or choose an exported JSON file." : "Nothing is created until you confirm. Imported routines start disabled.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain)
            }.padding(20)
            Divider()
            if let grokBundles { GrokImportPreview(bundles: grokBundles) } else if let plan { preview(plan) } else { sourcePicker }
            Divider()
            HStack {
                if plan != nil || grokBundles != nil { Button("Back") { plan = nil; grokBundles = nil; errorMessage = nil } }
                Spacer(); Button("Cancel") { dismiss() }
                if let grokBundles {
                    Button(isImporting ? "Importing…" : "Import \(grokBundles.count) bots") {
                        guard !isImporting else { return }
                        isImporting = true
                        do { try store.importGrokBundles(grokBundles); dismiss() } catch { isImporting = false; self.grokBundles = nil; show(error) }
                    }.buttonStyle(.borderedProminent).disabled(isImporting)
                }
                if let plan {
                    Button(isImporting ? "Importing…" : "Import agent") {
                        guard !isImporting else { return }
                        isImporting = true
                        _ = store.importTemplate(plan)
                        dismiss()
                    }.buttonStyle(.borderedProminent).disabled(isImporting)
                }
            }.padding(16)
        }
        .frame(width: 680, height: 680).background(AppColor.panel)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try prepare(Data(contentsOf: url, options: .mappedIfSafe)) }
            catch { show(error) }
        }
    }

    private var sourcePicker: some View {
        Form {
            Section("Share link") {
                TextField("https://…/export.json", text: $shareLink)
                Button(isLoading ? "Checking…" : "Load link") { loadLink() }.disabled(isLoading || shareLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("AgentApp accepts only a direct JSON response. It never scrapes a share page.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Exported file") { Button("Choose JSON file…") { choosingFile = true } }
            Section("Grok Bot export") {
                Button("Choose export folder or bundle.json…") { choosingExport = true }
                Text("Folder written by scripts/export-grokbot.py. Bots, avatars and a read-only Grok history are imported; importing again updates without duplicates.").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage { Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            Section { Text("Only import a template you own or are allowed to use. Credentials, tokens, passwords, private keys, and similar sensitive fields are rejected and never shown in the preview.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding(8)
        .fileImporter(isPresented: $choosingExport, allowedContentTypes: [.folder, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { grokBundles = try GrokBundleLoader.load(from: url); errorMessage = nil } catch { show(error) }
        }
    }

    private func preview(_ plan: TemplateImportPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { AvatarImage(name: plan.avatarName).frame(width: 46, height: 46).clipShape(Circle()); VStack(alignment: .leading) { Text(plan.manifest.name).font(.headline); Text(plan.manifest.title).foregroundStyle(.secondary) } }
                reviewBlock("Instructions", plan.manifest.instructions)
                ForEach(Array(plan.manifest.memories.enumerated()), id: \.offset) { _, memory in reviewBlock("Memory · \(memory.name)", memory.value) }
                ForEach(plan.manifest.skills) { skill in reviewBlock("Skill · \(skill.name)", skill.markdown) }
                ForEach(Array(plan.manifest.routines.enumerated()), id: \.offset) { _, routine in
                    reviewBlock("Routine · \(routine.name)", [routine.schedule.map { "Schedule: \($0)" }, routine.trigger.map { "Trigger: \($0)" }, routine.prompt.isEmpty ? nil : routine.prompt].compactMap { $0 }.joined(separator: "\n"))
                }
                if let skill = plan.manifest.gettingStartedSkill { reviewBlock("Getting started · \(skill.name)", skill.markdown) }
                Text("Import report").font(.headline).padding(.top, 4)
                ForEach(plan.report) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(item.status)).foregroundStyle(color(item.status)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(item.name).fontWeight(.medium); Text(item.status.rawValue.capitalized).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(color(item.status).opacity(0.12), in: Capsule()) }
                            Text(item.category + " · " + item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(20)
        }
    }

    private func loadLink() {
        isLoading = true; errorMessage = nil
        let link = shareLink
        Task {
            do { let data = try await TemplateImportLoader.load(link: link); try prepare(data) }
            catch { show(error) }
            isLoading = false
        }
    }
    private func prepare(_ data: Data) throws { plan = store.makeImportPlan(from: try GrokTemplateParser.parse(data)); errorMessage = nil }
    private func reviewBlock(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.bold()).foregroundStyle(.secondary); Text(content.isEmpty ? "Not provided" : content).font(.callout).textSelection(.enabled) }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }
    private func show(_ error: Error) { errorMessage = (error as? TemplateImportError)?.localizedDescription ?? (error as? GrokBundleError)?.localizedDescription ?? "The template could not be loaded. Export it as JSON and try the file instead." }
    private func icon(_ status: TemplateImportStatus) -> String { switch status { case .mapped: "checkmark.circle.fill"; case .converted: "arrow.triangle.2.circlepath.circle.fill"; case .skipped: "minus.circle.fill"; case .unsupported: "xmark.circle.fill" } }
    private func color(_ status: TemplateImportStatus) -> Color { switch status { case .mapped: .green; case .converted: .blue; case .skipped: .orange; case .unsupported: .red } }
}
