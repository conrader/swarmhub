import SwiftUI
@preconcurrency import BotAvatarsKit

/// One mark in one of two layers: an app-owned still drawing, or the kit's live view while it idles or works.
/// Both come from the same body, colour and size; switching cross-fades for 0.2 s (none under Reduce Motion).
struct AvatarMarkView: View {
    let shape: String; let colour: AvatarColour; let size: CGFloat; let mode: AvatarMotionMode; let seed: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let type = AvatarKitMap.body(for: shape).type
        let hex = colour.hex(dark: colorScheme == .dark)
        ZStack {
            if mode == .still {
                AvatarStillMark(type: type, colourHex: hex, size: size).equatable().transition(.opacity)
            } else {
                AvatarLiveMark(type: type, colourHex: hex, size: size, working: mode == .working, seed: AvatarKitMap.kitSeed(seed)).transition(.opacity)
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
                drawBotAvatarFrame(&context, box: Double(canvas.width) / BOT_AVATAR_OVERSCAN, pose: .rest(.default), cfg: config, state: BotAvatarRenderState())
            }
            .frame(width: size * BOT_AVATAR_OVERSCAN, height: size * BOT_AVATAR_OVERSCAN)
            .offset(y: -BOT_AVATAR_RISE * size)
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

/// The live layer: the kit's own view, flat, never interactive (clicks reach the row's button), no idle jumps or flips.
/// While one exists the shared clock runs; it stops when the last one leaves.
struct AvatarLiveMark: View {
    let type: BotAvatarType; let colourHex: String; let size: CGFloat; let working: Bool; let seed: Double

    var body: some View {
        BotAvatarsKit.BotAvatar(type: type, state: working ? .working : .default, size: Double(size), color: BotColor(colourHex),
                                brightness: 1, saturation: 1, paused: false, seed: seed, shading: .flat, rim: 0,
                                interactive: false, jump: BotAvatarJumpConfig(every: 0))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { UISmokeProbe.liveAvatarViews += 1 }
            .onDisappear { UISmokeProbe.liveAvatarViews -= 1 }
    }
}
