import SwiftUI

/// P35 D5: the sidebar's "On this box · not connected" (one per connection, hidden when empty): each profile left out,
/// with selection, local deletion and Connect (SwarmHub connects it after confirmation, or paste its key).
struct BoxNotConnectedSections: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let targets = store.boxProfiles.keys.filter { !(store.boxProfiles[$0] ?? []).isEmpty }.sorted()
        ForEach(targets, id: \.self) { target in
            VStack(alignment: .leading, spacing: 0) {
                Text(BoxCopy.sectionTitle(place: targets.count > 1 ? BoxAddress.url(target).map(BoxAddress.place) : nil))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.horizontal, SidebarMetrics.rowPadding).padding(.top, 10).padding(.bottom, 2)
                ForEach(store.boxProfiles[target] ?? []) { profile in BoxProfileRow(profile: profile, target: target) }
            }.chromeProbe("sidebar_not_connected")
        }
    }
}

private struct BoxProfileRow: View {
    @EnvironmentObject private var store: AppStore
    let profile: BoxProfile; let target: String
    @State private var hovering = false
    @State private var showingDelete = false
    var body: some View {
        let selected = store.selectedBoxProfile == BoxProfileSelection(target: target, name: profile.name)
        HStack(spacing: SidebarMetrics.markGap) {
            Button { store.open(profile, on: target) } label: {
                HStack(spacing: SidebarMetrics.markGap) {
                    Image(systemName: "circle.dashed").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).frame(width: SidebarMetrics.mark)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.botName).font(.system(size: SidebarMetrics.nameSize, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(BoxCopy.rowLine(profile.state)).font(.system(size: 12)).foregroundStyle(profile.state == .failed ? .orange : .secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }.frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open \(profile.botName)").accessibilityAddTraits(selected ? .isSelected : [])
            if profile.state == .adopting {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    if profile.state != .needsKey { Button(BoxCopy.connectAutomatically) { store.offerAdoption(profile, on: target) } }
                    SettingsPaneButton(title: BoxCopy.pasteKey, pane: .servers)
                } label: { Text(BoxCopy.connect).font(.system(size: 12, weight: .medium)) }
                    .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).menuIndicator(.hidden).fixedSize()
            }
        }
        .modifier(RowChrome(selected: selected, hovering: hovering)).onHover { hovering = $0 }
        .help(profile.name == "default" ? BoxCopy.mainBotWhy : profile.state == .needsKey ? BoxCopy.typedWhy : BoxCopy.rowLine(profile.state))
        .contextMenu {
            Button("Open", systemImage: "bubble.left") { store.open(profile, on: target) }
            if profile.state != .needsKey {
                Button(BoxCopy.connectAutomatically, systemImage: "link") { store.offerAdoption(profile, on: target) }.disabled(profile.state == .adopting)
            }
            SettingsPaneButton(title: BoxCopy.pasteKey, pane: .servers)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { showingDelete = true }.disabled(profile.state == .adopting)
        }
        .modifier(BoxProfileDeleteAlert(profile: profile, target: target, isPresented: $showingDelete))
    }
}

/// A disconnected bot can be inspected and managed before it has a chat or credentials.
struct BoxProfileDetailView: View {
    @EnvironmentObject private var store: AppStore
    let profile: BoxProfile; let target: String
    @State private var showingDelete = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.sidebarHidden { HideSidebarButton() }
                Spacer()
            }.padding(.horizontal, 12).frame(height: ChromeMetrics.titleRow).windowDragStrip(probe: "disconnected_bot_strip")
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "circle.dashed").font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
                Text(profile.botName).font(.title2.weight(.semibold))
                Text(BoxCopy.rowLine(profile.state)).foregroundStyle(.secondary)
                Text(profile.name == "default" ? BoxCopy.mainBotWhy : profile.state == .needsKey ? BoxCopy.typedWhy : "Connect this bot to start chatting.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    if profile.state == .adopting {
                        ProgressView().controlSize(.small)
                    } else if profile.state != .needsKey {
                        Button(BoxCopy.connect) { store.offerAdoption(profile, on: target) }.buttonStyle(.borderedProminent)
                    }
                    SettingsPaneButton(title: BoxCopy.pasteKey, pane: .servers)
                }
                Button("Delete Bot", role: .destructive) { showingDelete = true }.disabled(profile.state == .adopting)
            }.padding(24)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColor.chat)
            .modifier(BoxProfileDeleteAlert(profile: profile, target: target, isPresented: $showingDelete))
    }
}

private struct BoxProfileDeleteAlert: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let profile: BoxProfile; let target: String
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.alert("Delete \(profile.botName)?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { store.deleteBoxProfile(profile, on: target) }
        } message: {
            Text("This removes the bot from SwarmHub. It stays on your box. To add it again, use “Add all bots from this box” in Settings → Advanced → Servers and keys.")
        }
    }
}

/// P35 D3: the one confirmation for a batch: which bots, what the manager does to each, and how to undo it.
struct AdoptionSheet: View {
    @EnvironmentObject private var store: AppStore
    let offer: AdoptionOffer
    let close: () -> Void
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(BoxCopy.sheetTitle(offer.names.count)).font(.title3.bold())
            Text(BoxCopy.sheetDetail(manager: offer.managerName)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(offer.names, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal").foregroundStyle(.secondary).frame(width: 18)
                        Text(HermesProfileNaming.botName(forProfile: name))
                        Text(name).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(SetupCopy.cancel, action: close).keyboardShortcut(.cancelAction)
                Button(BoxCopy.connectButton(offer.names.count), action: confirm).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 460)
    }
    private func confirm() {
        guard let manager = store.bots.first(where: { $0.id == offer.managerID }), store.startAdoption(offer.names, manager: manager) else { failure = BoxCopy.busy; return }
        close()
    }
}

/// Settings → Servers and keys: "Add all bots from this box" (D1 again on demand), its result lines and the batch's sheet.
struct AddAllBotsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var lines: [String] = []
    @State private var running = false
    @State private var offer: AdoptionOffer?
    var body: some View {
        Section(BoxCopy.addAllButton) {
            Text(BoxCopy.addAllCaption).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(BoxCopy.addAllButton, action: run).disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            ForEach(lines, id: \.self) { line in Text(line).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: $offer) { AdoptionSheet(offer: $0) { offer = nil }.environmentObject(store) }
    }
    private func run() {
        running = true; lines = []
        Task {
            let found = await store.addAllBotsFromBoxes()
            lines = found.lines; offer = found.offer; running = false
        }
    }
}

/// The bot editor's undo for a bot SwarmHub connected by re-keying it (P35 D3).
struct RestoreOldKeySection: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    @ObservedObject var bot: Bot
    @State private var failure: String?
    var body: some View {
        if bot.adoptedKeyBackup != nil, let manager = store.manager(for: bot), manager.id != bot.id {
            Section("Key on the box") {
                Button(BoxCopy.restoreButton) { if store.restoreOldKey(bot) { dismiss() } else { failure = BoxCopy.busy } }
                Text(BoxCopy.restoreCaption).font(.caption).foregroundStyle(.secondary)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}
