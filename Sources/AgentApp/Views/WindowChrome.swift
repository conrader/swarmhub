import AppKit
import SwiftUI

/// The main window has no title bar (briefs/P14.md): each pane's header is the window's top edge and drag strip.
enum ChromeMetrics {
    /// The sidebar's top row: the system title zone (28 pt with a hidden title bar).
    static let titleRow: CGFloat = 28
    /// Leading room that keeps controls clear of the traffic lights: measured `lights.max_x` (73 on macOS 26.6.2) + 8.
    static let lightsClearance: CGFloat = 81
    /// The chat and group headers' horizontal padding; the show-sidebar item sits after `lightsClearance - headerPadding`.
    static let headerPadding: CGFloat = 20
    /// Today's Details/Members panel width, kept by both right-column mechanisms.
    static let infoWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (300, 330, 380)
}

/// What a mouse-down on a drag strip does. Pure, so the tests can walk every branch.
enum WindowDragDecision: Equatable {
    case system, drag, zoom, miniaturize, nothing

    /// Full screen is left alone. A double-click anywhere on the strip, the system's title zone included (with the title bar
    /// hidden nothing there answers it), follows the user's "double-click a window's title bar" setting; a single click in
    /// the title zone goes to the system, any other click drags the window.
    static func decide(isFullScreen: Bool, yFromTop: CGFloat, systemZone: CGFloat, clickCount: Int, doubleClickAction: String?) -> Self {
        if isFullScreen { return .system }
        if clickCount == 2 { return doubleClick(doubleClickAction) }
        return yFromTop < systemZone ? .system : .drag
    }

    /// `AppleActionOnDoubleClick` as set in System Settings → Desktop & Dock (the global domain), nil when never set.
    static func doubleClickSetting(globalDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)) -> String? {
        globalDomain?["AppleActionOnDoubleClick"] as? String
    }

    /// `AppleActionOnDoubleClick`: unset or Maximize → zoom, Minimize → miniaturize, None → nothing.
    static func doubleClick(_ action: String?) -> Self {
        switch action {
        case "Minimize": .miniaturize
        case "None": .nothing
        default: .zoom
        }
    }
}

/// Moves the window from a pane header; `isMovableByWindowBackground` stays false so text selection and drops still work.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        let decision = WindowDragDecision.decide(isFullScreen: window.styleMask.contains(.fullScreen), yFromTop: window.frame.height - event.locationInWindow.y,
                                                 systemZone: window.frame.height - window.contentLayoutRect.maxY,
                                                 clickCount: event.clickCount,
                                                 doubleClickAction: WindowDragDecision.doubleClickSetting())
        switch decision {
        case .system: super.mouseDown(with: event)
        case .drag: window.performDrag(with: event)
        case .zoom: window.zoom(nil)
        case .miniaturize: window.miniaturize(nil)
        case .nothing: break
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

/// An invisible view that tells `--ui-smoke` where a piece of chrome sits; it never takes a click.
final class ChromeProbeView: NSView {
    var probeID = "" { didSet { register() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
    private func register() { if window != nil, !probeID.isEmpty { ChromeProbes.register(self, id: probeID) } }
}

struct ChromeProbe: NSViewRepresentable {
    let id: String
    init(_ id: String) { self.id = id }
    func makeNSView(context: Context) -> ChromeProbeView { let view = ChromeProbeView(); view.probeID = id; return view }
    func updateNSView(_ view: ChromeProbeView, context: Context) { if view.probeID != id { view.probeID = id } }
}

extension View {
    /// A pane header as the window's drag strip (ahead of its background colour), reported to the smoke as `probe`.
    func windowDragStrip(probe: String) -> some View { background(ChromeProbe(probe)).background(WindowDragArea()) }
    func chromeProbe(_ id: String) -> some View { background(ChromeProbe(id)) }
}

/// "Hide sidebar" in the sidebar's top row.
struct HideSidebarButton: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Button { store.sidebarHidden = true } label: { Image(systemName: "sidebar.left").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).help("Hide sidebar").accessibilityLabel("Hide sidebar").chromeProbe("hide_sidebar")
    }
}

/// P41: back from a thread to the chat. A plain icon button inside a drag strip needs a content shape: without one a
/// click beside the glyph falls through to the strip and drags the window.
struct ThreadBackButton: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Button { store.closeThread() } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help("Back to chat").accessibilityLabel("Back to chat").chromeProbe("thread_back")
    }
}

/// While the sidebar is hidden, "Show sidebar" leads the chat and group headers, clear of the traffic lights.
struct ShowSidebarItem: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        if store.sidebarHidden {
            HStack(spacing: 0) {
                Color.clear.frame(width: ChromeMetrics.lightsClearance - ChromeMetrics.headerPadding, height: 1)
                Button { store.sidebarHidden = false } label: { Image(systemName: "sidebar.left").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Show sidebar").accessibilityLabel("Show sidebar").chromeProbe("show_sidebar")
            }
        }
    }
}

/// How the Details/Members column opens and closes; the smoke reports which one is live.
enum RightColumnMechanism: String {
    case inspector, transition
    static let current = RightColumnMechanism.inspector
}

/// The right column slides like the sidebar (briefs/P14.md item 8): SwiftUI's inspector, or a trailing move as the fallback.
/// Reduce Motion: no slide.
struct RightColumn<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    var mechanism = RightColumnMechanism.current
    @ViewBuilder let panel: () -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let motion: Animation? = reduceMotion ? nil : .smooth(duration: 0.25)
        switch mechanism {
        case .inspector:
            content.ignoresSafeArea(.container, edges: .top)
                .inspector(isPresented: $isPresented) {
                    panel().inspectorColumnWidth(min: ChromeMetrics.infoWidth.min, ideal: ChromeMetrics.infoWidth.ideal, max: ChromeMetrics.infoWidth.max)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .animation(motion, value: isPresented)
        case .transition:
            HStack(spacing: 0) {
                content
                if isPresented { HStack(spacing: 0) { Divider(); panel() }.transition(reduceMotion ? .identity : .move(edge: .trailing)) }
            }.animation(motion, value: isPresented)
        }
    }
}

extension View {
    func rightColumn<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(RightColumn(isPresented: isPresented, panel: panel))
    }
}
