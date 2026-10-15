import SwiftUI

/// P36: the Reports inbox in the main window: rows (bot avatar or "You", kind, title, time) and the selected report's
/// detail. Opening it refreshes the sent reports' status.
struct ReportsInboxView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var center: ReportsCenter

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Reports").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if center.refreshing { ProgressView().controlSize(.small) }
                    Button { store.startUserReport() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("Report a problem…")
                }.padding(.horizontal, 16).frame(height: 52)
                Divider()
                ReportList(center: center).frame(maxHeight: .infinity, alignment: .top)
            }.frame(width: 320).background(AppColor.panel)
            Divider()
            Group {
                if let report = center.selected { ReportDetailView(center: center, report: report).id(report.id) }
                else { Text(ReportsCopy.empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColor.chat)
        }
        .task { await store.refreshReportStatuses() }
    }
}

enum ReportsCopy {
    static let empty = "No reports. When a bot hits a SwarmHub limit, its report waits here for you."
    static let review = "Nothing leaves this Mac until you press Send. Remove anything you would rather not share."
}

struct ReportList: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var center: ReportsCenter
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(center.inbox.visible) { report in
                    Button { center.selectedID = report.id } label: { ReportRow(report: report, bot: store.reportBot(report), selected: center.selectedID == report.id) }
                        .buttonStyle(.plain)
                }
                if center.inbox.visible.isEmpty { Text(ReportsCopy.empty).font(.callout).foregroundStyle(.secondary).padding(16) }
            }.padding(8)
        }
    }
}

struct ReportRow: View {
    let report: SwarmReport; let bot: Bot?; var selected = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let bot { BotAvatar(bot: bot, size: 30) } else { YouMark(size: 30) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bot?.name ?? (report.source == .user ? "You" : report.bot ?? "A bot")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    KindChip(kind: report.kind)
                    Spacer(minLength: 4)
                    Text(report.createdAt, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(report.title.isEmpty ? "Untitled report" : report.title).font(.system(size: 13, weight: report.state == .pending ? .semibold : .regular))
                    .lineLimit(2).foregroundStyle(report.title.isEmpty ? .secondary : .primary)
                if report.state == .sent { StatusChip(status: report.status ?? "received") }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
}

struct YouMark: View {
    var size: CGFloat
    var body: some View {
        Text("You").font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: size, height: size).background(Circle().fill(Color.primary.opacity(0.1)))
    }
}

struct KindChip: View {
    let kind: ReportKind
    var body: some View {
        Text(kind.label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(kind == .bug ? Color.red : Color.blue).background(Capsule().fill((kind == .bug ? Color.red : Color.blue).opacity(0.14)))
    }
}

struct StatusChip: View {
    let status: String
    var body: some View {
        Text(status.capitalized).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.secondary).background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// One report: editable title and body while pending, the facts it carries, Send to SwarmHub / Dismiss; once sent the
/// server's status and note.
struct ReportDetailView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var center: ReportsCenter
    let report: SwarmReport
    @State private var title = ""; @State private var bodyText = ""; @State private var kind = ReportKind.bug

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if report.state == .pending { editor } else { sentHeader }
                facts
                if report.state == .pending { actions }
                if let error = center.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding(24).frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { title = report.title; bodyText = report.body; kind = report.kind }
        .onChange(of: title) { save() }.onChange(of: bodyText) { save() }
    }

    private func save() {
        guard report.state == .pending, title != report.title || bodyText != report.body else { return }
        center.inbox.edit(report.id, title: title, body: bodyText)
    }

    @ViewBuilder private var editor: some View {
        HStack { KindChip(kind: report.kind); Text(report.source == .user ? "Your report" : "From \(store.reportBot(report)?.name ?? report.bot ?? "a bot")").foregroundStyle(.secondary) }
        TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.system(size: 15, weight: .medium))
        if report.hasBody || !bodyText.isEmpty {
            TextEditor(text: $bodyText).font(.system(size: 13)).frame(minHeight: 140).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(AppColor.card)).overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColor.separator))
        } else {
            Label("Fetching the report from the box…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        }
        Text(ReportsCopy.review).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var sentHeader: some View {
        HStack { KindChip(kind: report.kind); StatusChip(status: report.status ?? "received") }
        Text(report.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
        if let note = report.note {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note from SwarmHub").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(note).textSelection(.enabled)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(AppColor.raised))
        }
        Text(report.body).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attached").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let bot = report.bot, report.source == .agent { fact("Bot", "\(store.reportBot(report)?.name ?? bot) (\(report.botBackend.map { $0 == "hermes" ? "Hermes" : $0 } ?? "Hermes"))") }
            if !report.skillVersions.isEmpty { fact("Skills", report.skillVersions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
            if let hermes = report.hermesVersion { fact("Hermes", hermes) }
            fact("App", "\(AppConstants.name) \(report.appVersion ?? store.appVersionText)")
            if let id = report.serverID { fact("Report", "#\(id)") }
        }.font(.callout)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(name).foregroundStyle(.secondary).frame(width: 64, alignment: .leading); Text(value).textSelection(.enabled) }
    }

    private var actions: some View {
        HStack {
            Button("Send to SwarmHub") { Task { await store.sendReport(report.id) } }
                .buttonStyle(.borderedProminent).disabled(center.sendingID != nil || title.trimmingCharacters(in: .whitespaces).isEmpty || !report.hasBody)
            Button("Dismiss", role: .destructive) { store.dismissReport(report.id) }
            if center.sendingID == report.id { ProgressView().controlSize(.small) }
        }
    }
}

extension ReportsCenter {
    var isSignedIn: Bool { if case .signedIn = account { true } else { false } }
}

/// Settings → Account: the SwarmHub service address (for tests). P40: there is no sign-in; reports and app connections
/// use this Mac's anonymous install.
struct SettingsSwarmHubAccountPane: View {
    @ObservedObject var center: ReportsCenter
    @AppStorage(SwarmHubService.baseURLKey) private var serviceURL = ""
    var body: some View {
        Section("SwarmHub service") {
            Text("Reports and app connections use this Mac's anonymous install key. There is no account to manage.").font(.caption).foregroundStyle(.secondary)
            TextField("SwarmHub service", text: $serviceURL, prompt: Text(SwarmHubService.defaultBaseURL))
            Text("Leave empty for \(SwarmHubService.defaultBaseURL).").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Reports: the same inbox; a row opens it in the main window.
struct SettingsReportsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var center: ReportsCenter
    var body: some View {
        Section("Reports") {
            if center.inbox.visible.isEmpty { Text(ReportsCopy.empty).foregroundStyle(.secondary) }
            ForEach(center.inbox.visible) { report in
                Button { store.openReports(select: report.id) } label: { ReportRow(report: report, bot: store.reportBot(report)) }.buttonStyle(.plain)
            }
            Button("Report a problem…") { store.startUserReport() }
        }
    }
}

/// The sidebar's "Reports" row with the pending count; shown once there is a report.
struct ReportsSidebarRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var center: ReportsCenter
    var body: some View {
        if !center.inbox.visible.isEmpty {
            Button { store.openReports() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 13))
                    Text("Reports").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if center.inbox.pendingCount > 0 {
                        Text("\(center.inbox.pendingCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Color.accentColor))
                    }
                }.padding(.horizontal, SidebarMetrics.rowPadding).frame(height: 36).contentShape(Rectangle())
                .background(store.showingReports ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius))
            }.buttonStyle(.plain).padding(.top, 6).accessibilityLabel("Reports, \(center.inbox.pendingCount) waiting")
        }
    }
}
