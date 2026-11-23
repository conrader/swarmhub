import SwiftUI

struct ReleaseNote: Identifiable {
    let version: SemanticVersion
    let body: String
    var id: String { version.description }

    static let bundled: [ReleaseNote] = {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var roots = [Bundle.main.resourceURL, executable.appending(path: "AgentApp.resources")].compactMap { $0 }
        #if SWIFT_PACKAGE
        if Bundle.main.bundleURL.pathExtension != "app", let resources = Bundle.module.resourceURL { roots.append(resources) }
        #endif
        for root in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root.appending(path: "releases"), includingPropertiesForKeys: nil) else { continue }
            let notes = files.compactMap { file -> ReleaseNote? in
                guard file.pathExtension == "md", let version = SemanticVersion(file.deletingPathExtension().lastPathComponent),
                      let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let lines = text.components(separatedBy: .newlines)
                let body = lines.first?.hasPrefix("# SwarmHub ") == true ? lines.dropFirst().joined(separator: "\n") : text
                return ReleaseNote(version: version, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !notes.isEmpty { return notes.sorted { $0.version > $1.version } }
        }
        return []
    }()
}

struct WhatsNewPane: View {
    @State private var expanded = Set(ReleaseNote.bundled.prefix(1).map(\.id))
    private let installed = SemanticVersion(AppBuildInfo.current().version)

    var body: some View {
        Form {
            if ReleaseNote.bundled.isEmpty { Text("Release notes are unavailable in this build.") }
            ForEach(ReleaseNote.bundled) { note in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(note.id) }, set: { open in
                    if open { expanded.insert(note.id) } else { expanded.remove(note.id) }
                })) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(note.body.components(separatedBy: "\n").filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                            Text((try? AttributedString(markdown: line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line,
                                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }.padding(.vertical, 6)
                } label: {
                    HStack {
                        Text("Version \(note.id)").font(.headline)
                        if installed == note.version { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}
