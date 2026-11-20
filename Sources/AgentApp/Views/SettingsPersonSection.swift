import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPersonSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverID: String?

    var body: some View {
        let servers = store.herdrServers
        let server = servers.first { $0.id == serverID } ?? servers[0]
        VStack(alignment: .leading, spacing: 12) {
            GroupHeading(title: "Time zone & location")
            if servers.count > 1 {
                Picker("Workspace", selection: Binding(get: { server.id }, set: { serverID = $0 })) {
                    ForEach(servers) { Text($0.name).tag($0.id) }
                }
            }
            Editor(server: server, model: store.personSettings(for: server)).id(server.place + server.id + server.address)
        }
    }

    private struct Editor: View {
        @EnvironmentObject private var store: AppStore
        let server: HerdrServer
        @ObservedObject var model: HerdrPersonSettings
        @State private var city = ""
        @State private var region = ""
        @State private var country = ""
        @State private var exportError = false
        private static let zones = Set(TimeZone.knownTimeZoneIdentifiers).union(["UTC"])

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Follow this Mac’s time zone", isOn: Binding(get: { model.preferences.followsMac }, set: model.followMac))
                Picker("Time zone", selection: Binding(get: { model.zone }, set: model.pin)) {
                    ForEach(Self.zones.union([model.zone]).sorted(), id: \.self) { Text($0).tag($0) }
                }.disabled(model.preferences.followsMac)
                Divider()
                Toggle("Use this Mac’s location", isOn: Binding(get: { model.preferences.usesDeviceLocation }, set: model.useDeviceLocation))
                Text("Shares the approximate city, region, and country with this workspace’s bots.").font(.callout).foregroundStyle(.secondary)
                if model.preferences.usesDeviceLocation {
                    if let label = model.profile.location?.label { Text(label).foregroundStyle(.secondary) }
                } else {
                    TextField("City", text: $city)
                    TextField("Region (optional)", text: $region)
                    TextField("Country (optional)", text: $country)
                    HStack {
                        Button("Save location") { model.save(PersonPlace.manual(city: city, region: region, country: country)) }
                            .disabled(city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.profile.location != nil { Button("Clear location") { model.save(nil) } }
                    }
                }
                if let status = model.status { Text(status).font(.callout).foregroundStyle(.secondary) }
                Button("Export profile…", action: exportProfile)
                    .disabled(model.profile.updatedAt == nil)
                if exportError { Text("Couldn’t export this profile.").font(.callout).foregroundStyle(.secondary) }
            }
            .onAppear { model.read() }
            .onChange(of: model.profile.location, initial: true) { _, place in
                city = place?.city ?? ""
                region = place?.region ?? ""
                country = place?.country ?? ""
            }
        }

        private func exportProfile() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "SwarmHub Person Profile.json"
            panel.allowedContentTypes = [.json]
            panel.begin { answer in
                guard answer == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        let profile = try await store.herdrClient(for: server).exportPersonProfile()
                        try profile.write(to: url, options: .atomic)
                        exportError = false
                    } catch { exportError = true }
                }
            }
        }
    }
}
