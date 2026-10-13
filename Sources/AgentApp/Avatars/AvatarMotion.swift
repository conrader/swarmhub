import AppKit
import Combine
import SwiftUI

/// Where a mark is shown. `still` marks never move (message authors, pickers); the other three follow `AvatarMotion`.
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
        case .byContext: "List rows stay still unless that bot is working or hovered; the open bot's large mark and welcome views idle gently."
        case .calm: "Every mark behaves like a list row: still unless its bot is working or hovered."
        case .off: "Marks never move."
        }
    }
}

/// What a mark does right now: drawn still, or a live kit view idling (blinks, glances) or working (hops).
enum AvatarMotionMode: String, Sendable { case still, idle, working }

enum AvatarMotion {
    /// The truth table of briefs/P15.md item 10: Reduce Motion or Off → still; working → hops everywhere;
    /// Calm makes every context a list; a list row idles only while hovered; focus and showcase idle continuously.
    static func resolve(context: AvatarMotionContext, isWorking: Bool, isHovered: Bool, reduceMotion: Bool, preference: AvatarMotionPreference) -> AvatarMotionMode {
        if context == .still || reduceMotion || preference == .off { return .still }
        if isWorking { return .working }
        let effective = preference == .calm ? AvatarMotionContext.list : context
        switch effective {
        case .list: return isHovered ? .idle : .still
        case .focus, .showcase: return .idle
        case .still: return .still
        }
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

/// Whether idle marks may run: the app is active and its main window is visible (not occluded or minimised).
/// Working marks ignore this; idle marks draw still while it is false, so the clock stops in the background.
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
