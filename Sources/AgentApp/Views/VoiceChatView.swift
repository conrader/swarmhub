import AppKit
import SwiftUI

/// P38 C: the "Voice with ChatGPT" window: a live spoken conversation, its transcript, and saving it for a reviewed
/// handoff to the chat it was opened from.
struct VoiceChatView: View {
    static let windowID = "voice-conversation"
    @ObservedObject var voice: CodexVoiceSession = .shared
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice with ChatGPT").font(.title2.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Experimental").font(.caption).foregroundStyle(.secondary).padding(6).background(.quaternary, in: Capsule())
            }
            Image(systemName: voice.isMuted ? "mic.slash.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 76, weight: .ultraLight)).foregroundStyle(voice.isLive ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true).padding(.top, 8)
            VStack(spacing: 8) {
                Text(status).font(.headline).accessibilityIdentifier("voice.status")
                if voice.isBusy { ProgressView().controlSize(.small) }
                if voice.isLive { Text("Speak naturally. You can interrupt at any time.").font(.callout).foregroundStyle(.secondary) }
                else if let name = voice.contextName, voice.canUseVoice {
                    Toggle("Include recent text from \(name)", isOn: $voice.includeContext).toggleStyle(.checkbox).disabled(voice.isBusy)
                }
                if let failure = voice.failure { VoiceFailureBox(voice: voice, failure: failure) }
            }
            HStack(spacing: 12) {
                if !voice.canUseVoice {
                    VStack(spacing: 8) {
                        if voice.failure?.step != .account { Text(voice.accessMessage).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                        Button("Voice settings") { store.settingsPane = .voice; openSettings() }
                    }
                } else if voice.isLive {
                    Button { voice.toggleMute() } label: { Label(voice.isMuted ? "Unmute" : "Mute", systemImage: voice.isMuted ? "mic.slash" : "mic") }
                    Button("Stop speaking") { voice.interruptPlayback() }
                    Button("End voice", role: .destructive) { voice.stop() }.buttonStyle(.borderedProminent)
                } else if voice.state == .connecting {
                    Button("Cancel") { voice.stop() }
                } else {
                    Button("Start voice") { voice.start() }.buttonStyle(.borderedProminent).disabled(voice.isBusy)
                        .accessibilityIdentifier("voice.start")
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if voice.transcript.entries.isEmpty { Text("Your live transcript will appear here.").font(.callout).foregroundStyle(.secondary) }
                        ForEach(voice.transcript.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.role == "user" ? "You" : "ChatGPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: voice.transcript.entries) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            SavedVoiceView(voice: voice)
            Text("Save a transcript before starting another voice conversation. Sending an instruction requires the reviewed handoff above.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 480, minHeight: 560)
            .background(AppColor.chat)
            .task { voice.account?.refresh(force: false) }
            .onDisappear { voice.stop() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in voice.stop() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in voice.stop() }
    }
    private var subtitle: String {
        guard let account = voice.account else { return "Not set up" }
        return account.isConnected ? "Connected app · \(account.plan?.capitalized ?? "ChatGPT")" : "Connect ChatGPT to check voice access"
    }
    private var status: String {
        switch voice.state {
        case .idle:
            if let failure = voice.failure, failure.step != .account {
                [.sendAudio, .realtime, .playback].contains(failure.step) ? "Voice stopped" : "Voice did not start"
            } else if voice.canUseVoice { "Ready to talk" }
            else if voice.account == nil { "ChatGPT connection needed" }
            else if voice.account?.isConnected == true { "Subscription voice unavailable" }
            else { "ChatGPT connection required" }
        case .connecting: "Starting voice…"
        case .live: voice.isMuted ? "Microphone muted" : "Voice is live"
        case .ending: "Ending voice…"
        }
    }
}

/// P55: why voice stopped, kept until "Dismiss" or the next start: the step's own line, the microphone pane when access
/// is off, and "Copy details" (step, type, code, redacted message).
struct VoiceFailureBox: View {
    @ObservedObject var voice: CodexVoiceSession
    let failure: LiveVoiceFailure
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(failure.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.callout).accessibilityIdentifier("voice.error")
            Text("Step: \(failure.step.title)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if failure.opensMicrophoneSettings { Button("Open Microphone settings") { ExternalLink.open(ExternalLink.microphoneSettings) } }
                Button("Copy details") { voice.copyDetails() }.accessibilityIdentifier("voice.copyDetails")
                Spacer()
                Button("Dismiss") { voice.dismissFailure() }.accessibilityIdentifier("voice.dismissError")
            }.controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// P38 C: the chat header's way into live voice, carrying a text snapshot of this chat. Shown only when the build has
/// a ChatGPT connection; while voice is not available for the account it opens Settings → Voice, which says why.
struct OpenVoiceButton: View {
    @ObservedObject var voice: CodexVoiceSession = .shared
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let name: String
    let target: ConversationActionTarget?
    let messages: () -> [(role: String, text: String)]
    var body: some View {
        if voice.account != nil {
            Button {
                if voice.canUseVoice {
                    voice.prepareContext(name: name, messages: messages(), target: target)
                    openWindow(id: VoiceChatView.windowID)
                } else { store.settingsPane = .voice; openSettings() }
            } label: { Image(systemName: "waveform").frame(width: 22, height: 22) }
            .buttonStyle(.plain).foregroundStyle(voice.canUseVoice ? Color.primary : Color.secondary)
            .help(voice.canUseVoice ? "Open voice with ChatGPT" : "Voice with ChatGPT: \(voice.accessMessage)")
            .accessibilityLabel(voice.canUseVoice ? "Open voice with ChatGPT" : "Voice settings")
            .accessibilityIdentifier("chat.openVoice")
        }
    }
}
