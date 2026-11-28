import SwiftUI

extension HerdrClient {
    /// `GET /api/ais`: the AI programs on the server (`service.rs`), as `service status` lists them.
    struct ServerAIs: Decodable, Sendable, Equatable {
        struct Program: Decodable, Sendable, Equatable, Identifiable {
            let id: String
            let name: String
            let installed: Bool
            /// The server has a template for it, so a bot can run on it.
            var templateWritten: Bool? = nil
            /// The server can install it by itself (npm carries it and npm is there).
            var canInstall: Bool? = nil
            let how: String
        }
        let programs: [Program]
    }

    func serverAIs() async throws -> ServerAIs { try await get("/api/ais") }

    func addServerAI(_ id: String) async throws -> ServerAIs { try await post("/api/ais/\(id)", [:]) }

    /// npm can take minutes on a small server.
    func installServerAI(_ id: String) async throws -> ServerAIs { try await post("/api/ais/\(id)/install", [:], timeout: 660) }
}

/// Settings → Servers: the AI programs on a server reached over SSH, where "AIs on this Mac" does not apply.
/// A server without this feature shows nothing.
struct HerdrServerAIsBlock: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    @State private var programs: [HerdrClient.ServerAIs.Program]?
    @State private var note = ""
    @State private var working = false

    var body: some View {
        Group {
            if let programs, server.kind != .local {
                SettingBlock(title: "AIs on \(server.name)",
                             detail: "Bots on this server run on the AIs added here. Signing in to an AI is done once, in its terminal on the server.") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(programs) { program in
                            HStack {
                                Text(program.name)
                                Spacer()
                                if program.installed && program.templateWritten == true {
                                    Label("Added", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                                } else if program.installed {
                                    Button("Add") { Task { await change(program, install: false) } }
                                        .disabled(working).accessibilityLabel("Add " + program.name)
                                } else if program.canInstall == true {
                                    Button("Install") { Task { await change(program, install: true) } }
                                        .disabled(working).accessibilityLabel("Install " + program.name)
                                } else {
                                    Text("Not installed").foregroundStyle(.secondary)
                                }
                            }
                            if !program.installed, program.canInstall != true {
                                Text(program.how).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        if working { ProgressView().controlSize(.small).accessibilityLabel("Working on the server") }
                        if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        .task(id: server.id) {
            guard store.launchWorkEnabled, let client = try? store.herdrClient(for: server) else { programs = nil; return }
            programs = try? await client.serverAIs().programs
        }
    }

    private func change(_ program: HerdrClient.ServerAIs.Program, install: Bool) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let client = try store.herdrClient(for: server)
            let answer = install ? try await client.installServerAI(program.id) : try await client.addServerAI(program.id)
            programs = answer.programs
            note = program.name + (install ? " was installed and added. Sign in to it once in its terminal on the server." : " was added.")
        } catch { note = error.localizedDescription }
    }
}
