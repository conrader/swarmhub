import AppKit
import SwiftUI

/// Settings → Software Update: the one place that answers "is everything up to date?". It opens like
/// System Settings' own Software Update: the app's icon, one sentence and one button. Under it, this Mac's app with
/// its two switches, and every Herdr server as a card that says what runs there and what, if anything, is behind.
///
/// The app is updated by Sparkle (`AppUpdater`): Update Now opens its window with the release notes and Install. A
/// server's workspace is updated by the server itself (`SoftwareUpdateModel`); Herdr Core by Herdr's own command.
struct SoftwareUpdatePane: View {
    /// The app's own line, as plain values so a render needs no updater.
    struct AppLine: Equatable {
        var version: String
        var available: String? = nil
        var checking = false
        var lastCheck: Date? = nil
        var problem: String? = nil
        /// Why this build cannot update itself (a development build); the switches are hidden with it.
        var unavailable: String? = nil
        var checksAutomatically = true, installsAutomatically = false, mayInstallAutomatically = true

        var state: SoftwareUpdateSummary.App {
            if let available { return .available(available) }
            return unavailable == nil && lastCheck != nil ? .upToDate : .unknown
        }

        var sentence: String {
            if let unavailable { return unavailable }
            if let available { return "Version \(available) is available. Update Now shows what is new and installs it." }
            if checking { return "Checking…" }
            if let problem { return "Could not check: \(problem)" }
            guard let lastCheck else { return "Not checked yet." }
            return "Up to date. Last checked \(lastCheck.formatted(.relative(presentation: .named)))."
        }
    }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updater: AppUpdater
    @ObservedObject private var live = SoftwareUpdateModel.shared
    @State private var release: UpdateStatus?
    private let info = AppBuildInfo.current()
    /// Renders: the servers' states and the app's line as given, and nothing is asked.
    var preset: SoftwareUpdateModel? = nil
    var presetApp: AppLine? = nil

    private var model: SoftwareUpdateModel { preset ?? live }
    private var app: AppLine {
        presetApp ?? AppLine(version: info.version + (info.build.map { " (\($0))" } ?? ""), available: updater.available, checking: updater.isChecking,
                             lastCheck: updater.lastCheck, problem: updater.problem, unavailable: updater.unavailableReason,
                             checksAutomatically: updater.automaticallyChecksForUpdates, installsAutomatically: updater.automaticallyDownloadsUpdates,
                             mayInstallAutomatically: updater.allowsAutomaticUpdates)
    }

    var body: some View {
        let servers = store.herdrServers, app = app
        let summary = SoftwareUpdateSummary(app: app.state, servers: servers.map(model.state(for:)))
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            VStack(spacing: 14) {
                HeroHeader(title: summary.headline, detail: Self.detail(summary, servers: servers.map(\.name))) { UpdateMark(summary: summary) }
                HStack(spacing: 10) {
                    if let action = summary.action { Button(action) { updateAll(summary) }.buttonStyle(.appleProminent).controlSize(.large).keyboardShortcut(.defaultAction) }
                    Button("Check Now") { checkNow() }.controlSize(.large).disabled(summary.isChecking || summary.isWorking || app.checking)
                }
            }.frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                GroupHeading(title: "This Mac")
                appCard(app)
                if app.unavailable == nil {
                    SettingSwitch(title: "Check for updates automatically", detail: "Once a day, in the background. Nothing opens over your work: an update shows as a line in the sidebar and here.",
                                  symbol: "clock.arrow.circlepath", colour: AppColor.sky, isOn: Binding(get: { app.checksAutomatically }, set: updater.setAutomaticallyChecksForUpdates))
                    SettingSwitch(title: "Install updates automatically", detail: "A new version downloads in the background and installs when you quit \(AppConstants.name). Every update is checked against \(AppConstants.name)’s signing key before it is opened.",
                                  symbol: "arrow.down.circle.fill", colour: AppColor.sage, isOn: Binding(get: { app.installsAutomatically }, set: updater.setAutomaticallyDownloadsUpdates))
                        .disabled(!app.mayInstallAutomatically)
                }
            }

            if !servers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    GroupHeading(title: servers.count == 1 ? "Your server" : "Your servers",
                                 detail: "A server runs the \(AppConstants.name) workspace beside Herdr Core. Updating the workspace restarts only the workspace: your agents keep running.")
                    ForEach(servers) { server in
                        ServerUpdateCard(server: server, state: model.state(for: server), stale: model.staleMachines[server.id] ?? [], canGoBack: model.canGoBack[server.id] ?? false,
                                         update: { run { await $0.update(server, store: store) } }, check: { run { await $0.check(server, store: store) } },
                                         updateCore: { run { await $0.updateCore(server, store: store) } }, goBack: { run { await $0.goBack(server, store: store) } })
                    }
                }
            }
        }
        .task {
            guard preset == nil, presetApp == nil else { return }
            updater.checkQuietly()
            await live.refresh(store: store)
        }
    }

    /// One sentence under the headline: what is ready to install, or what was looked at. `servers`: their names, in
    /// the order of the summary's states.
    nonisolated static func detail(_ summary: SoftwareUpdateSummary, servers: [String]) -> String {
        if summary.isWorking { return "The workspace restarts by itself. Your agents keep running." }
        func list(_ names: [String]) -> String { names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.first ?? "" }
        if summary.updates > 0 {
            let ready = zip(servers, summary.servers).filter { $0.1.installable != nil }.map(\.0)
            let parts = [summary.appUpdate.map { "\(AppConstants.name) \($0)" }, ready.isEmpty ? nil : "the workspace on \(list(ready))"].compactMap { $0 }
            return list(parts).prefix(1).uppercased() + list(parts).dropFirst() + "."
        }
        return servers.isEmpty ? "\(AppConstants.name)." : "\(AppConstants.name) and the workspace on \(servers.count == 1 ? "your server" : "your \(servers.count) servers")."
    }


    private func appCard(_ app: AppLine) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconMark(size: 40) { SymbolTile(symbol: "arrow.down.app.fill", colour: AppColor.sky, size: 36) }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(AppConstants.name) \(app.version)").font(.headline)
                Text(app.sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let release {
                    Text(release.message).font(.callout).foregroundStyle(.secondary)
                    if case .newer(let found) = release, let page = found.pageURL { Link(SimpleCopy.openRelease(found.name ?? found.tag), destination: page).font(.callout) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if app.available != nil { Button("Update Now…") { updater.checkForUpdates() }.buttonStyle(.appleProminent) }
            else if app.checking { ProgressView().controlSize(.small) }
            else if app.state == .upToDate { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(AppColor.good).accessibilityLabel("Up to date") }
        }.appleCard(padding: 12)
    }

    private func run(_ work: @escaping @MainActor (SoftwareUpdateModel) async -> Void) {
        guard preset == nil else { return }
        let model = live
        Task { await work(model) }
    }

    private func checkNow() {
        guard preset == nil else { return }
        updater.checkQuietly()
        // A build that Sparkle cannot update (a development build) still says whether a newer release is out.
        if updater.unavailableReason != nil { Task { release = await ReleaseChecker.check(current: info.version) } }
        run { await $0.refresh(store: store) }
    }

    /// The servers first, one after another; then the app, whose update ends with a relaunch.
    private func updateAll(_ summary: SoftwareUpdateSummary) {
        guard preset == nil else { return }
        let model = live, appBehind = summary.appUpdate != nil
        Task {
            await model.updateAll(store: store)
            if appBehind { updater.checkForUpdates() }
        }
    }
}

/// The app's icon with what the page says in one mark: a tick, an arrow, or a spinner.
private struct UpdateMark: View {
    let summary: SoftwareUpdateSummary
    var body: some View {
        AppIconMark(size: 76) { SymbolTile(symbol: "arrow.down.app.fill", colour: AppColor.sky, size: 66) }
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if summary.isChecking || summary.isWorking { ProgressView().controlSize(.small).padding(5).background(.regularMaterial, in: Circle()) }
                    else if summary.updates > 0 { badge("arrow.down.circle.fill", AppColor.sky) }
                    else if summary.needsHand > 0 { badge("exclamationmark.circle.fill", AppColor.clay) }
                    else if summary.headline == "Everything is up to date" { badge("checkmark.circle.fill", AppColor.sage) }
                }.offset(x: 4, y: 4)
            }.accessibilityHidden(true)
    }
    private func badge(_ symbol: String, _ colour: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 24)).symbolRenderingMode(.palette).foregroundStyle(.white, colour).background(Circle().fill(.white).padding(3))
    }
}

/// One server: what runs there, what is behind, and the one button that fixes it.
private struct ServerUpdateCard: View {
    let server: HerdrServer
    let state: HerdrServerUpdate
    /// Its project servers whose Herdr helper needs an update.
    let stale: [String]
    let canGoBack: Bool
    let update: () -> Void, check: () -> Void, updateCore: () -> Void, goBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.headline)
                if let versions = Self.versions(state) { Text(versions).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !state.line.isEmpty {
                    Text(state.line).font(.callout).foregroundStyle(warns ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let note = state.coreNote { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if !stale.isEmpty {
                    HStack(spacing: 8) {
                        Text("Herdr on \(stale.joined(separator: ", ")) needs an update.").font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("Update Herdr", action: updateCore).controlSize(.small).disabled(state.isBusy)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if state.isBusy { ProgressView().controlSize(.small) }
                else if state.installable != nil { Button("Update", action: update).buttonStyle(.appleProminent) }
                else if good { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(AppColor.good).accessibilityLabel("Up to date") }
                else if warns { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17)).foregroundStyle(AppColor.caution).accessibilityLabel("Needs attention") }
                Menu {
                    Button("Check Again", action: check)
                    Button("Update Herdr Core", action: updateCore)
                    if canGoBack, let from = state.bridge?.version { Button("Go Back from Workspace \(from)", action: goBack) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(state.isBusy || !state.reached).accessibilityLabel("More for \(server.name)")
            }
        }.appleCard(padding: 12)
    }

    private var good: Bool {
        switch state.phase { case .upToDate, .updated: true; default: false }
    }
    private var warns: Bool {
        switch state.phase { case .manual, .failed, .rolledBack, .unreachable: true; default: false }
    }

    /// "Workspace 0.2.0 · Herdr Core 0.1.21", with whichever of the two the server told.
    static func versions(_ state: HerdrServerUpdate) -> String? {
        let parts = [state.bridge.map { "Workspace \($0.version)" }, state.coreVersion.map { "Herdr Core \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The sidebar's line when something is behind: one quiet button that opens Software Update.
struct UpdateNoticeLine: View {
    @ObservedObject private var notice = UpdateNotice.shared
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let line = notice.line {
            Button { store.settingsPane = .updates; openSettings() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(.tint)
                    Text(line).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 30).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open Software Update").accessibilityLabel(line)
        }
    }
}
