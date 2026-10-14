import Foundation

// TORVLI: use the rig's existing pointer-following controls to aim at content without a mouse.
public enum BotAvatarGaze: String, CaseIterable, Sendable {
    case forward, left, right, down

    private var x: Double { self == .left ? -1.2 : self == .right ? 1.2 : 0 }
    private var y: Double { self == .down ? 1.2 : 0 }

    /// The library keeps every animation; the target only steers its head and eyes.
    public func apply(to sim: BotAvatarSim) { sim.setPointer(x: x, y: y, strength: 1) }

    /// Matches the engine's settled pointer target, with no rig or clock for static marks.
    public func restPose(_ state: BotAvatarState = .default) -> BotAvatarPose {
        var pose = BotAvatarPose.rest(state)
        pose.yaw = 22 * .pi / 180 * x
        pose.pitch -= 12 * .pi / 180 * y
        pose.lookX += 4.5 * x
        pose.lookY += 3 * y
        return pose
    }
}
