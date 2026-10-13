# BotAvatarsKit — vendored copy

- Upstream: https://github.com/Jakubantalik/Libraries.dev (`packages/bot-avatars/ports/ios/BotAvatarsKit`)
- Pin: `a27566557b4def79bcdcedc71858c0fb28020b6d` (main, 2026-10-13). Upstream has no tags and does not build on macOS
  unpatched, so this is a pinned copy, not a SwiftPM dependency.
- Licence: MIT, Jakub Antalik (`LICENSE` beside this file, `packages/bot-avatars/LICENSE` at the pin; repeated in the
  repo's `THIRD-PARTY-NOTICES.md`). No Pro or Studio content is used.
- Built as its own target in Swift 5 language mode (`Package.swift`; `scripts/build.sh` compiles it as a separate
  module on the swiftc path). Torvli itself stays Swift 6.

## Blob SHAs at the pin (`git hash-object`)

| File | Upstream blob | Here |
|------|---------------|------|
| `LICENSE` | `0e9405a2ee75ce720c665c04568fedda3c07906a` | unchanged |
| `BotAvatar.swift` | `c8f70c4fb2d8b2571dcb0736002acc200f69436a` | unchanged |
| `BotAvatarClock.swift` | `45efd1c37d2f33f78f7fd462cf6af460e2d256f8` | patched (a), (c) |
| `BotAvatarColor.swift` | `864d02443302953928da395c4e578c81b790e3d9` | patched (b) |
| `BotAvatarDraw.swift` | `91feb934bf84e67cc0cc59781916b6826dce3bc6` | unchanged |
| `BotAvatarEngine.swift` | `2c36ab42cceee37a81c8ea3391486b496369858a` | unchanged |
| `BotAvatarPlastic.swift` | `8816c12be75ee87aa14cc57fc3a5ce3106e34a5b` | unchanged |
| `BotAvatarShapes.swift` | `bd02cd6f8eb6d100d6b63de241b80f8ad3f86930` | unchanged |
| `BotAvatarStage.swift` | `522f2b093104ea666634e015c696728e853442bc` | unchanged |
| `BotAvatarTypes.swift` | `475875a4a63fffedc3e6ae12d9b4996b304c0e55` | unchanged |

## Patches (each marked `// TORVLI:`)

- (a) `BotAvatarClock.swift`: `CADisplayLink(target:selector:)` is iOS-only. It stays under `#if canImport(UIKit)`;
  on macOS the clock takes `(NSScreen.main ?? NSScreen.screens.first)?.displayLink(target:selector:)` (macOS 14) with
  `preferredFrameRateRange` 24–60, preferred 30, and does not start when there is no screen. `AppKit` is imported for it.
- (b) `BotAvatarColor.swift`: `BotColor.init(_ color: Color)` used `UIColor`; the AppKit variant resolves
  `NSColor(color).usingColorSpace(.sRGB)`.
- (c) `BotAvatarClock.swift`: `public var isRunning: Bool { link != nil }`.

No further compile fixes were needed (Apple Swift 6.4, macOS 27 SDK, both `swift build` and the swiftc fallback).

To re-check: `git hash-object Vendor/BotAvatarsKit/Sources/BotAvatarsKit/*.swift Vendor/BotAvatarsKit/LICENSE`.
