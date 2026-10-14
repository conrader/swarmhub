import SwiftUI
@preconcurrency import BotAvatarsKit

/// One mark in one of two layers: an app-owned still drawing, or the kit's live view while it idles or works.
/// Both come from the same body, colour and size; switching cross-fades for 0.2 s (none under Reduce Motion).
struct AvatarMarkView: View {
    let shape: String; let colour: AvatarColour; let size: CGFloat; let mode: AvatarMotionMode; let seed: String
    var facing: AvatarFacing = .forward; var context: AvatarMotionContext = .focus; var calm = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let type = AvatarKitMap.body(for: shape).type
        let hex = colour.hex(dark: colorScheme == .dark)
        ZStack {
            if mode == .still {
                AvatarStillMark(type: type, colourHex: hex, size: size, facing: facing).equatable().transition(.opacity)
            } else {
                AvatarLiveMark(type: type, colourHex: hex, size: size, seed: AvatarKitMap.kitSeed(seed),
                               facing: facing, playback: AvatarMotion.playback(mode: mode, context: context, calm: calm)).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
    }
}

/// The still layer: the kit's public renderer drawn once at its rest pose, in a canvas `BOT_AVATAR_OVERSCAN`× the size
/// raised by `BOT_AVATAR_RISE` (as the kit lays out its own view). No clock, gestures or model; configured when the body
/// runs, and `Equatable` so a sidebar re-rendering on every streamed token does not redraw it.
struct AvatarStillMark: View, Equatable {
    let type: BotAvatarType; let colourHex: String; let size: CGFloat
    var facing: AvatarFacing = .forward

    static func config(type: BotAvatarType, colourHex: String) -> BotAvatarDrawConfig {
        var config = BotAvatarDrawConfig(type: type, color: BotColor(colourHex))
        config.shading = .flat
        config.rim = 0
        config.still = true
        return config
    }

    var body: some View {
        let config = Self.config(type: type, colourHex: colourHex)
        Color.clear.frame(width: size, height: size).overlay {
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvas in
                drawBotAvatarFrame(&context, box: Double(canvas.width) / BOT_AVATAR_OVERSCAN, pose: facing.kitGaze.restPose(), cfg: config, state: BotAvatarRenderState())
            }
            .frame(width: size * BOT_AVATAR_OVERSCAN, height: size * BOT_AVATAR_OVERSCAN)
            .offset(y: -BOT_AVATAR_RISE * size)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

/// The live layer: Libraries.dev's original animation rig, flat shading and a content gaze target.
/// While one exists the shared clock runs; it stops when the last one leaves.
struct AvatarLiveMark: View {
    let type: BotAvatarType; let colourHex: String; let size: CGFloat; let seed: Double
    let facing: AvatarFacing; let playback: AvatarPlayback

    var body: some View {
        BotAvatarsKit.BotAvatar(type: type, state: playback.state, size: Double(size), color: BotColor(colourHex),
                                brightness: 1, saturation: 1, speed: playback.speed, paused: false, seed: seed, shading: .flat, rim: 0,
                                interactive: false, jump: playback.jump, gaze: facing.kitGaze, reaction: playback.reaction)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { UISmokeProbe.liveAvatarViews += 1 }
            .onDisappear { UISmokeProbe.liveAvatarViews -= 1 }
    }
}

extension AvatarFacing {
    var kitGaze: BotAvatarGaze {
        switch self { case .forward: .forward; case .left: .left; case .right: .right; case .down: .down }
    }
}

/// Selects the library's ready-made states and tap gesture; contains no animation curves or pose overrides.
struct AvatarPlayback {
    let state: BotAvatarState; let jump: BotAvatarJumpConfig; let speed: Double; let reaction: Int; let scenario: String
}

extension AvatarMotion {
    static func playback(mode: AvatarMotionMode, context: AvatarMotionContext, calm: Bool) -> AvatarPlayback {
        let state: BotAvatarState
        let reaction: Int
        let scenario: String
        switch mode {
        case .still, .idle: state = .default; reaction = 0; scenario = context == .list ? "idle" : "focused"
        case .hovered: state = .default; reaction = 2; scenario = "greeting"
        case .working: state = .working; reaction = 0; scenario = "working"
        case .waiting: state = .sleeping; reaction = 0; scenario = "waiting"
        case .celebrating: state = .default; reaction = 1; scenario = "completion"
        }
        return AvatarPlayback(state: state, jump: calm ? BotAvatarJumpConfig(every: 0) : .defaults,
                              speed: calm ? 0.55 : 1, reaction: calm ? 0 : reaction, scenario: scenario)
    }
}
