import AppKit
import Combine
import SwiftUI

/// Where a mark is shown. Message authors and pickers stay still; visible conversational marks stay alive.
enum AvatarMotionContext: String, Sendable { case still, list, focus, showcase }

/// Settings → Appearance → Avatar motion.
enum AvatarMotionPreference: String, CaseIterable, Identifiable, Sendable {
    case byContext, calm, off
    var id: String { rawValue }
    var title: String {
        switch self { case .byContext: "By context"; case .calm: "Calm everywhere"; case .off: "Off" }
    }
    var caption: String {
        switch self {
        case .byContext: "Avatars breathe and blink on their own, look toward the conversation, and react to hover, work, approvals and completed replies."
        case .calm: "Slower animation everywhere, with breathing and blinks, and no idle jumps or hover and completion reactions."
        case .off: "Marks never move."
        }
    }
}

/// Scenarios are selected from real activity; hover adds a greeting without enabling the clock.
enum AvatarMotionMode: String, CaseIterable, Sendable { case still, idle, hovered, working, waiting, celebrating }

/// The avatar's relationship to its content, independent of animation and pointer position.
enum AvatarFacing: String, CaseIterable, Sendable { case forward, left, right, down }

enum AvatarMotion {
    /// Accessibility wins, then approval, work, completion and hover. Idle never needs a pointer.
    static func resolve(context: AvatarMotionContext, isWorking: Bool, isHovered: Bool, reduceMotion: Bool, preference: AvatarMotionPreference,
                        isWaiting: Bool = false, isCelebrating: Bool = false) -> AvatarMotionMode {
        if context == .still || reduceMotion || preference == .off { return .still }
        if isWaiting { return .waiting }
        if isWorking { return .working }
        if isCelebrating && preference != .calm { return .celebrating }
        if isHovered && preference != .calm { return .hovered }
        return .idle
    }
}

/// The persisted preference (the app's UserDefaults), observed by every mark; `probeOverride` lets `--ui-smoke` try
/// Calm without touching the saved choice.
@MainActor final class AvatarMotionSettings: ObservableObject {
    static let shared = AvatarMotionSettings()
    static let key = "avatarMotion"
    private let defaults: UserDefaults

    @Published var preference: AvatarMotionPreference { didSet { defaults.set(preference.rawValue, forKey: Self.key) } }
    @Published var probeOverride: AvatarMotionPreference?
    var effective: AvatarMotionPreference { probeOverride ?? preference }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = defaults.string(forKey: Self.key).flatMap(AvatarMotionPreference.init(rawValue:)) ?? .byContext
    }
}

/// Whether marks may animate: the app is active and a main window is visible, not occluded or minimised.
/// All scenarios draw still in the background so the shared clock can stop.
@MainActor final class AvatarActivity: ObservableObject {
    static let shared = AvatarActivity()
    @Published private(set) var canIdle = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                          NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AvatarActivity.shared.update() }
            }
        }
        update()
    }

    func update() {
        guard let app = NSApp else { canIdle = true; return }
        let visible = app.windows.contains { $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible) && !$0.isMiniaturized }
        let next = app.isActive && visible
        if next != canIdle { canIdle = next }
    }
}

/// Successful replies publish a short-lived, presentation-only reaction. Never saved to the bot or store.
@MainActor final class AvatarReactions: ObservableObject {
    static let shared = AvatarReactions()
    static let celebrationDuration: TimeInterval = 2
    @Published private(set) var completions: [UUID: Date] = [:]

    func completed(_ bot: Bot) { completions[bot.id] = .now }
}
