import AppKit
import SwiftUI

/// A bot's avatar wherever it appears. A mark (Grok's words) has no circle, disc, ring or shadow and is never clipped
/// (hops overshoot); a classic avatar keeps them. `motion` picks the context; the parent passes `isWorking`
/// (`AppStore.isWorking`) and, for list rows, `isHovered`. `probe` names the place for `--ui-smoke`.
struct BotAvatar: View {
    let bot: Bot; var size: CGFloat = 38; var motion: AvatarMotionContext = .still
    var isWorking = false; var isHovered = false; var probe: String? = nil
    @ObservedObject private var settings = AvatarMotionSettings.shared
    @ObservedObject private var activity = AvatarActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: AvatarMotionMode {
        let resolved = AvatarMotion.resolve(context: motion, isWorking: isWorking, isHovered: isHovered, reduceMotion: reduceMotion, preference: settings.effective)
        return resolved == .idle && !activity.canIdle ? .still : resolved
    }

    var body: some View {
        let look = bot.avatarLook, mode = mode
        Group {
            switch look {
            case .mark(let shape, let colour):
                AvatarMarkView(shape: shape, colour: colour, size: size, mode: mode, seed: bot.avatarSeed)
            case .classic(let name):
                AvatarImage(name: name)
                    .scaledToFill().frame(width: size, height: size).clipShape(Circle())
                    .background(AppColor.raised, in: Circle())
                    .overlay(Circle().stroke(bot.accentColor.flatMap(Color.init(hex:)) ?? AppColor.separator, lineWidth: bot.accentColor == nil ? 0.75 : 1.5))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if reduceMotion && isWorking { Circle().fill(Color(nsColor: .systemGreen)).frame(width: 7, height: 7).offset(x: 1, y: 1) }
        }
        .onAppear { report(look, mode) }
        .onChange(of: mode) { _, next in report(look, next) }
        .onChange(of: look) { _, next in report(next, mode) }
        .onChange(of: bot.id) { old, _ in
            // The same view now shows another bot (ChatView keeps its identity across selections): drop the old fact.
            if let probe { UISmokeProbe.avatarFacts.removeValue(forKey: "\(probe)|\(old)") }
            report(look, mode)
        }
        .onDisappear { if let probe { UISmokeProbe.avatarFacts.removeValue(forKey: "\(probe)|\(bot.id)") } }
    }

    private func report(_ look: AvatarLook, _ mode: AvatarMotionMode) {
        guard let probe else { return }
        UISmokeProbe.avatarFacts["\(probe)|\(bot.id)"] = AvatarFacts.facts(bot: bot, look: look, mode: mode, size: size, place: probe)
    }
}

/// Up to four member marks with no disc (Grok's arrangement is unobserved): one at full size, two on the diagonal at
/// 0.68, three or four in a 2×2 grid at 0.5, each with a thin halo in the row's background colour where they overlap.
/// The answering member is live while the group works; all idle while the row is hovered (the list rule).
struct GroupAvatarStack: View {
    @EnvironmentObject private var store: AppStore
    let group: GroupChat; let members: [Bot]; var size: CGFloat = 28; var isHovered = false
    var halo: Color = AppColor.sidebar; var probe: String? = nil

    var body: some View {
        let shown = Array(members.prefix(4))
        let scale: CGFloat = shown.count <= 1 ? 1 : shown.count == 2 ? 0.68 : 0.5
        let small = size * scale
        ZStack(alignment: .topLeading) {
            if shown.isEmpty { Circle().fill(AppColor.raised).overlay(Image(systemName: "person.3").font(.system(size: size * 0.35))) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bot in
                BotAvatar(bot: bot, size: small, motion: .list, isWorking: store.isWorking(bot, in: group), isHovered: isHovered,
                          probe: probe.map { "\($0)#\(index)" })
                    .shadow(color: shown.count > 1 ? halo : .clear, radius: 0.6).shadow(color: shown.count > 1 ? halo : .clear, radius: 0.6)
                    .offset(offset(index, count: shown.count, small: small))
            }
        }.frame(width: size, height: size, alignment: .topLeading)
    }

    private func offset(_ index: Int, count: Int, small: CGFloat) -> CGSize {
        if count == 2 { return index == 0 ? .zero : CGSize(width: size - small, height: size - small) }
        return CGSize(width: index.isMultiple(of: 2) ? 0 : size - small, height: index < 2 ? 0 : size - small)
    }
}

extension AppStore {
    /// The bot is answering right now (anywhere). `UISmokeProbe.forcedWorking` is the smoke's 2 s override.
    func isWorking(_ bot: Bot) -> Bool { UISmokeProbe.forcedWorking == bot.id || (isStreaming && streamingBotID == bot.id) }
    /// The bot is answering in this group.
    func isWorking(_ bot: Bot, in group: GroupChat) -> Bool {
        UISmokeProbe.forcedWorking == bot.id || (isStreaming && streamingBotID == bot.id && streamingConversation === group)
    }
}

/// A mark that belongs to no bot yet (the Grok import preview): showcase context, idling gently by default.
struct ShowcaseMark: View {
    let mark: AvatarMark; let seed: String; var size: CGFloat = 30
    @ObservedObject private var settings = AvatarMotionSettings.shared
    @ObservedObject private var activity = AvatarActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let resolved = AvatarMotion.resolve(context: .showcase, isWorking: false, isHovered: false, reduceMotion: reduceMotion, preference: settings.effective)
        if case .mark(let shape, let colour) = AvatarLook.resolve(mark: mark, classic: .faceCoral, seed: seed) {
            AvatarMarkView(shape: shape, colour: colour, size: size, mode: resolved == .idle && !activity.canIdle ? .still : resolved, seed: seed)
        }
    }
}

/// An empty chat's welcome: the bot's mark large, in the showcase context.
struct ChatWelcome: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    var body: some View {
        VStack(spacing: 10) {
            BotAvatar(bot: bot, size: 72, motion: .showcase, isWorking: store.isWorking(bot), probe: "showcase")
            Text(bot.name).font(.system(size: 15, weight: .semibold))
            Text("Send a message to start.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}
