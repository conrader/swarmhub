import SwiftUI
import UserNotifications

/// Settings → General: you (your name, and what your bots should know about you), how the app looks, and
/// notifications. Laid out the way Apple lays out a person and an appearance: your initial with your name typed
/// beside it, choices as galleries of tiles and swatches, a switch beside its heading. Nothing here is a row of a
/// table, and opening the pane makes no network call and reads no key.
struct SettingsSimplePane: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference; @AppStorage("accent") private var accent = AppTheme.defaultAccent
    @AppStorage(AppIconAppearance.preferenceKey) private var appIcon = AppIconAppearance.defaultPreference
    @AppStorage("notifications") private var notifications = false
    @AppStorage(UserIdentity.key) private var accountName = ""
    @AppStorage(AppStore.aboutYouKey) private var aboutYou = ""
    @ObservedObject private var motion = AvatarMotionSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
                you
                appearanceGroup
                SettingSwitch(title: SimpleCopy.notifyMaster, detail: Bundle.main.bundleIdentifier == nil ? SimpleCopy.notifyNeedsApp : SimpleCopy.notifyCaption,
                              symbol: "bell.badge.fill", colour: AppColor.clay, isOn: $notifications)
                    .onChange(of: notifications) { _, enabled in
                        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
            }.padding(.horizontal, 32).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Your initial as the sidebar shows it, your name typed beside it, and "About you" beneath.
    private var you: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Text(UserIdentity.initial(of: accountName)).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56).background(Circle().fill(.tint)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    TextField(SimpleCopy.yourName, text: $accountName, prompt: Text(UserIdentity.fallback()))
                        .textFieldStyle(.plain).font(.title2.bold()).padding(.vertical, 4).padding(.horizontal, 10).frame(maxWidth: 300)
                        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).accessibilityLabel(SimpleCopy.yourName)
                    Text(SimpleCopy.yourNameCaption).font(.callout).foregroundStyle(.secondary).padding(.leading, 2)
                }
            }
            SettingBlock(title: AboutYouCopy.title, detail: AboutYouCopy.detail) {
                TextEditor(text: Binding(get: { aboutYou }, set: { aboutYou = String($0.prefix(HerdrAboutYou.limit)) }))
                    .font(.body).scrollContentBackground(.hidden).padding(8).frame(height: 96)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityLabel(AboutYouCopy.title)
                    .overlay(alignment: .topLeading) {
                        if aboutYou.isEmpty { Text(AboutYouCopy.prompt).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false) }
                    }
                Text(AboutYouCopy.count(aboutYou.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    /// The theme as three small windows to pick from, the app icon that goes with it, the accent as swatches, and how
    /// much the avatars move.
    private var appearanceGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupHeading(title: SimpleCopy.appearance)
            HStack(alignment: .top, spacing: 14) {
                ForEach([("Light", SimpleCopy.light), ("Dark", SimpleCopy.dark), ("System", SimpleCopy.system)], id: \.0) { value, name in
                    ThemeTile(value: value, name: name, selected: appearance == value) { appearance = value }
                }
            }.accessibilityElement(children: .contain).accessibilityLabel(SimpleCopy.theme)
            SettingBlock(title: SimpleCopy.appIcon, detail: SimpleCopy.appIconCaption) {
                Picker(SimpleCopy.appIcon, selection: $appIcon) { Text(SimpleCopy.light).tag("Light"); Text(SimpleCopy.dark).tag("Dark") }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            }
            SettingBlock(title: SimpleCopy.accent, detail: SimpleCopy.accentCaption) {
                HStack(spacing: 10) {
                    ForEach(AppTheme.accentNames, id: \.self) { name in
                        Button { accent = name } label: {
                            Circle().fill(AppTheme.accentColor(for: name).gradient).frame(width: 22, height: 22)
                                .overlay { if accent == name { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(name == "Graphite" ? Color(nsColor: .textBackgroundColor) : .white) } }
                                .padding(3).overlay { Circle().strokeBorder(accent == name ? AppTheme.accentColor(for: name) : .clear, lineWidth: 2) }
                        }.buttonStyle(.plain).help(name).accessibilityLabel(name).accessibilityAddTraits(accent == name ? .isSelected : [])
                    }
                }
            }
            SettingBlock(title: "Avatar motion", detail: motion.preference.caption) {
                Picker("Avatar motion", selection: $motion.preference) { ForEach(AvatarMotionPreference.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
        }
    }
}

/// One theme as a small window: its sidebar, a message from each side and the accent, in that theme's own colours.
/// "System" shows both halves.
private struct ThemeTile: View {
    let value: String; let name: String; let selected: Bool; let pick: () -> Void
    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                Group {
                    if value == "System" {
                        HStack(spacing: 0) { MiniWindow().environment(\.colorScheme, .light).frame(width: 60, alignment: .leading).clipped(); MiniWindow().environment(\.colorScheme, .dark).frame(width: 60, alignment: .trailing).clipped() }
                    } else {
                        MiniWindow().environment(\.colorScheme, value == "Dark" ? .dark : .light)
                    }
                }
                .frame(width: 120, height: 76).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.primary.opacity(0.12)), lineWidth: selected ? 2.5 : 1) }
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? .primary : .secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private struct MiniWindow: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            // The surfaces are resolved for the tile's own scheme, whatever the window around it is in.
            let dark = scheme == .dark
            let sidebar = Color(hex: dark ? "#181915" : "#F2F1E8") ?? .gray, chat = Color(hex: dark ? "#1E1F1B" : "#FDFCF8") ?? .gray
            let raised = Color(hex: dark ? "#2E3029" : "#EFEDE3") ?? .gray, ink = Color(hex: dark ? "#F7F7F2" : "#262821") ?? .primary
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 3) { Circle().fill([AppColor.clay, AppColor.sage, AppColor.sky][index]).frame(width: 7, height: 7); Capsule().fill(ink.opacity(0.35)).frame(width: 16, height: 3) }
                    }
                    Spacer(minLength: 0)
                }.padding(6).frame(width: 38, alignment: .leading).frame(maxHeight: .infinity).background(sidebar)
                VStack(spacing: 5) {
                    Capsule().fill(TintShapeStyle().opacity(0.35)).frame(width: 34, height: 9).frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule().fill(ink.opacity(0.3)).frame(width: 44, height: 4).frame(maxWidth: .infinity, alignment: .leading)
                    Capsule().fill(ink.opacity(0.3)).frame(width: 30, height: 4).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4).fill(raised).frame(height: 11)
                }.padding(7).frame(width: 82).frame(maxHeight: .infinity).background(chat)
            }.frame(width: 120, height: 76)
        }
    }
}

/// Version, the automatic check and Check for Updates (Sparkle), or a GitHub check when Sparkle cannot run here.
struct UpdateCheckRow: View {
    @EnvironmentObject private var updater: AppUpdater
    @State private var status: UpdateStatus?; @State private var checking = false
    private let info = AppBuildInfo.current()

    var body: some View {
        LabeledContent(SimpleCopy.version, value: info.version + (info.build.map { " (\($0))" } ?? ""))
        if updater.unavailableReason == nil {
            Toggle(SimpleCopy.autoCheck, isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticallyChecksForUpdates))
            Button(SimpleCopy.checkForUpdates, action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
            Text(SimpleCopy.autoCheckCaption).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack { Button(SimpleCopy.checkNow) { check() }.disabled(checking); if checking { ProgressView().controlSize(.small) } }
            if let status {
                Text(status.message).foregroundStyle(.secondary)
                if case .newer(let release) = status, let page = release.pageURL { Link(SimpleCopy.openRelease(release.name ?? release.tag), destination: page) }
            }
        }
    }

    private func check() {
        checking = true
        Task { status = await ReleaseChecker.check(current: info.version); checking = false }
    }
}
