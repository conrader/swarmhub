import SwiftUI

/// The wizard's last step on a server that can add project servers, and an optional one: "Where are your projects?".
/// It offers what Settings → Servers and keys → Projects offers: adding a project server (the Herdr server's key to
/// paste, the address, the fingerprint to check, the result), naming a first project on it, and choosing which
/// projects the main bot may use. Adding a server or a project happens on the Herdr server at once, by its own
/// button; the bots are still created by the wizard's last button, and going on without adding anything changes nothing.
struct SetupProjectsStep: View {
    @Binding var flow: SetupFlow
    @ObservedObject var model: HerdrProjectsModel
    @State private var addingServer = false

    var body: some View {
        VStack(spacing: 22) {
            HeroHeader(title: WizardCopy.projectsTitle, detail: WizardCopy.projectsIntro(server: flow.herdrServer?.name ?? "", main: flow.mainBotName)) {
                SymbolTile(symbol: "folder.fill", colour: AppColor.clay, size: 60)
            }
            VStack(alignment: .leading, spacing: 18) {
                switch model.phase {
                case .idle, .reading: StatusCard(kind: .working, title: WizardCopy.projectsReading)
                case .unavailable(let why): StatusCard(kind: .warning, title: WizardCopy.projectsUnavailable, detail: why)
                case .ready: ready
                }
            }.frame(maxWidth: AppleMetrics.column)
        }
        .task { if model.phase == .idle { await model.load() }; offerFirstProject() }
        .onChange(of: model.machines.count) { _, _ in offerFirstProject() }
    }

    @ViewBuilder private var ready: some View {
        StatusCard(kind: .info, title: HerdrProjectsCopy.consequence(flow.mainBotName), detail: WizardCopy.projectsSkip)
        ForEach(model.machines) { HerdrMachineCard(model: model, machine: $0) }
        if model.machines.isEmpty || addingServer || model.adding != .fields {
            HerdrAddMachineFlow(model: model, serverName: flow.herdrServer?.name ?? "")
        } else {
            Button(HerdrProjectsCopy.another) { addingServer = true }
        }
        if !model.machines.isEmpty {
            SettingBlock(title: model.projects.isEmpty ? WizardCopy.projectsFirst : WizardCopy.projectsFor(flow.mainBotName), detail: model.projects.isEmpty ? HerdrProjectsCopy.projectsDetail : nil) {
                ForEach(model.projects) { project in
                    let on = flow.mainProjects.contains { $0.id == project.id }
                    HerdrProjectCard(project: project, selected: on) {
                        Toggle(WizardCopy.projectsMayUse(flow.mainBotName, project.name), isOn: Binding(get: { on }, set: { choose(project, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel(WizardCopy.projectsMayUse(flow.mainBotName, project.name))
                    }
                }
                if model.draft != nil { HerdrProjectEditor(model: model, saved: { choose($0, true) }, canCancel: !model.projects.isEmpty) }
                else { Button(WizardCopy.projectsAnother) { model.newProject() } }
            }
        }
    }

    /// A server with no project yet shows the form for the first one at once.
    private func offerFirstProject() {
        if model.phase == .ready, !model.machines.isEmpty, model.projects.isEmpty, model.draft == nil { model.newProject() }
    }

    private func choose(_ project: HerdrProject, _ on: Bool) {
        flow.mainProjects.removeAll { $0.id == project.id }
        if on { flow.mainProjects.append(HerdrBotProject(project)) }
    }
}
