import SwiftUI

/// Scans the local executable inventory. Adding one program registers it for future bot launches.
struct SettingsAIsPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var report: HerdrLocalReport?
    @State private var offeredTemplates: Set<String>?
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    GroupHeading(title: "AIs on this Mac", detail: "Add an installed AI, then choose it in a bot’s Model tab.")
                    Spacer()
                    Button("Scan again") { Task { await refresh() } }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small).accessibilityLabel("Checking AIs") }
                if !message.isEmpty {
                    StatusCard(kind: failed ? .warning : .info, title: message)
                }
                if let report {
                    if report.canAddAi != true {
                        Text("Update this Mac’s workspace server to add newly installed AIs here.").foregroundStyle(.secondary)
                        SettingsPaneButton(title: "Software Update…", pane: .updates)
                    }
                    ForEach(report.programs) { program in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(program.name).font(.headline)
                                Spacer()
                                if program.installed && program.templateWritten == true {
                                    if offeredTemplates?.contains(program.template) == true {
                                        Label("Added", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                                    } else {
                                        Text(offeredTemplates == nil ? "Registered on this Mac" : "Unavailable on server")
                                            .foregroundStyle(.secondary)
                                    }
                                } else if program.installed {
                                    Button("Add AI") { Task { await refresh(adding: program) } }
                                        .buttonStyle(.appleProminent).disabled(busy || report.canAddAi != true)
                                        .accessibilityLabel("Add " + program.name)
                                } else {
                                    Text("Not detected").foregroundStyle(.secondary)
                                }
                            }
                            if !program.installed {
                                Text(program.how).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if let note = program.firstTime, program.id == "antigravity" {
                                Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.appleCard(padding: 12)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refresh() }
    }

    private func localServer(for report: HerdrLocalReport) -> HerdrServer? {
        let local = store.herdrServers.filter { $0.kind == .local }
        guard report.service.installed else { return local.first }
        return local.first { $0.port == report.port } ?? HerdrServer(
            id: "local-\(report.port)", name: "This Mac", kind: .local, address: HerdrServer.loopback(port: report.port))
    }

    private func refresh(adding program: HerdrLocalReport.Program? = nil) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        message = ""; failed = false
        let service = store.localService
        guard service.isPlaced else {
            report = nil; message = "Set up the workspace on this Mac to connect local AIs."; return
        }
        offeredTemplates = nil
        let inventory: HerdrLocalReport
        do {
            if let program {
                inventory = try await service.addAI(program.id, port: nil)
            } else {
                inventory = try await service.status(port: nil)
            }
            try Task.checkCancellation()
            report = inventory
        } catch {
            if Task.isCancelled { return }
            report = nil
            failed = true; message = error.localizedDescription
            return
        }

        do {
            if let program, inventory.program(template: program.template)?.templateWritten != true {
                throw HerdrLocalFailure(kind: "template", message: "The workspace could not register " + program.name + ".")
            }
            guard let server = localServer(for: inventory) else {
                if let program { message = program.name + " registered. Set up this Mac’s workspace to use it in a chat." }
                return
            }
            let available = try await store.herdrTemplates(on: server)
            try Task.checkCancellation()
            let names = Set(available.map(\.name))
            offeredTemplates = names
            store.localAIRevision += 1
            if let program {
                guard names.contains(program.template) else {
                    throw HerdrLocalFailure(kind: "template", message: "The local server could not load the template for " + program.name + ".")
                }
                message = program.name + " added. Choose it in your bot’s Model tab."
            }
        } catch {
            if Task.isCancelled { return }
            failed = true; message = error.localizedDescription
        }
    }
}
