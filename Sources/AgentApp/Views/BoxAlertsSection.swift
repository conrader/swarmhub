import SwiftUI

/// Settings → Advanced → Appearance and alerts → "When SwarmHub is closed": per server, where the box sends its alerts
/// (ntfy, email), a test alert and the alert service's state (`AppStore+BoxAlerts.swift`). Words: `AlertsCopy`.
struct BoxAlertsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BoxAlertsCache

    var body: some View {
        Section(AlertsCopy.title) {
            Text(AlertsCopy.caption).font(.caption).foregroundStyle(.secondary)
            let servers = store.hermesConnections
            if servers.isEmpty { Text(AlertsCopy.noServers).foregroundStyle(.secondary) }
            ForEach(servers, id: \.target) { server in BoxAlertsServerView(target: server.target, host: server.host, cache: cache) }
            Text(AlertsCopy.presenceNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BoxAlertsServerView: View {
    @EnvironmentObject private var store: AppStore
    let target: String, host: String
    @ObservedObject var cache: BoxAlertsCache
    @State private var settings = AlertSettings()
    @State private var ntfyToken = ""
    @State private var emailPassword = ""
    @State private var expanded: Bool

    init(target: String, host: String, cache: BoxAlertsCache, expanded: Bool = false) {
        self.target = target; self.host = host; self.cache = cache
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let state = cache.state(for: target)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                status(state)
                Toggle(AlertsCopy.ntfy, isOn: $settings.ntfyOn)
                if settings.ntfyOn {
                    TextField(AlertsCopy.ntfyURL, text: $settings.ntfyURL, prompt: Text(AlertsCopy.ntfyPlaceholder))
                    SecureField(AlertsCopy.ntfyToken, text: $ntfyToken)
                }
                Toggle(AlertsCopy.email, isOn: $settings.emailOn)
                if settings.emailOn { emailFields }
                Toggle(AlertsCopy.window, isOn: $settings.window)
                Text(AlertsCopy.windowHint).font(.caption).foregroundStyle(.secondary)
                Text(AlertsCopy.secretsNote).font(.caption).foregroundStyle(.secondary)
                actions(state)
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(host).fontWeight(.medium)
                Spacer()
                if let panel = state.panel { Text(headline(panel)).font(.caption).foregroundStyle(panel.service.running ? Color.green : Color.secondary) }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var emailFields: some View {
        TextField(AlertsCopy.emailHost, text: $settings.emailHost)
        TextField(AlertsCopy.emailPort, value: $settings.emailPort, format: .number.grouping(.never))
        Picker(AlertsCopy.emailSecurity, selection: $settings.emailSecurity) {
            ForEach(AlertSettings.Security.allCases, id: \.self) { Text(AlertsCopy.security($0)).tag($0) }
        }
        TextField(AlertsCopy.emailUser, text: $settings.emailUser)
        SecureField(AlertsCopy.emailPassword, text: $emailPassword)
        TextField(AlertsCopy.emailFrom, text: $settings.emailFrom)
        TextField(AlertsCopy.emailTo, text: $settings.emailTo)
    }

    @ViewBuilder private func status(_ state: ServerAlertsState) -> some View {
        if let panel = state.panel {
            let service = panel.service
            Text(headline(panel)).fontWeight(.medium).foregroundStyle(service.running ? Color.green : Color.secondary)
            if !service.running, panel.config.configured { Text(service.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let sent = service.lastSentAt { Text(AlertsCopy.lastSent(Self.relative(sent))).font(.caption).foregroundStyle(.secondary) }
            if let error = service.lastError { Text(AlertsCopy.lastError(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let until = service.presenceUntil, until > Date().timeIntervalSince1970 {
                Text(AlertsCopy.held(Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary)
            }
        } else if !store.alertsAreLocal(target) {
            Text(AlertsCopy.loadCaption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actions(_ state: ServerAlertsState) -> some View {
        HStack {
            Button(state.panel == nil ? AlertsCopy.load : AlertsCopy.refresh) { Task { await store.refreshAlerts(on: target) } }
            Button(AlertsCopy.save) {
                var chosen = settings
                chosen.enabled = true
                Task { await store.saveAlerts(chosen, ntfyToken: ntfyToken, emailPassword: emailPassword, on: target) }
            }
            .disabled(!settings.hasSink)
            Button(AlertsCopy.test) { Task { await store.sendTestAlert(on: target) } }.disabled(state.panel?.config.configured != true)
            Button(AlertsCopy.turnOff) { Task { await store.turnOffAlerts(on: target) } }.disabled(state.panel?.config.enabled != true)
            Spacer()
            if state.busy != nil { ProgressView().controlSize(.small); Text(AlertsCopy.working).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(state.busy != nil)
    }

    private func headline(_ panel: BoxAlertsPanel) -> String {
        if panel.service.running { return AlertsCopy.running }
        return panel.config.configured ? (panel.config.enabled ? AlertsCopy.notRunning : AlertsCopy.off) : AlertsCopy.notSetUp
    }

    static func relative(_ stamp: Double) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: stamp), relativeTo: .now)
    }

    /// The saved settings and Keychain secrets; Hermes on this Mac also reads the box's state at once (no model turn).
    private func load() {
        settings = store.alertSettings(for: target)
        ntfyToken = store.alertSecret("ntfy", target: target)
        emailPassword = store.alertSecret("smtp", target: target)
        if store.alertsAreLocal(target), cache.state(for: target).panel == nil, store.botInfo.autoLoad {
            Task { await store.refreshAlerts(on: target) }
        }
    }
}
