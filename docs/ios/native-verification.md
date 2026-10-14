# SwarmHub native iOS verification

14 October 2026 · Native foundation implementation

The iPhone app is in `Apps/iOS`, with shared code in `Packages/SwarmHubCore`. Verification used a separate development checkout on the Mac. No installed desktop app was replaced, no personal server was contacted, and no production Keychain or conversation data was used.

| Check | Result |
| --- | --- |
| Xcode simulator SDK build | Passed with Xcode 27.0 / Swift 6.4, deployment target iOS 18.0 |
| Simulator binary architectures | `arm64` and `x86_64` |
| Bundle identifier | `com.konrad.swarmhub.ios` |
| Native simulator launch and screen capture | Passed on a dedicated iPhone 16 Pro simulator running iOS 18.3; Chats, Conversation, Approvals and Settings inspected in dark/light appearances |
| Shared unit and real-HTTP fixture suite | 20 tests passed, including profile isolation, canonical history, streaming, manual approval acknowledgment, Stop, steer transport and interrupted-stream handling |
| Desktop regression suite | 459 tests passed on the combined tree, including the latest desktop key-store changes and the shared text encoder |
| Desktop direct-compiler fallback | Passed with `SWARMHUB_FORCE_SWIFTC=1`; shared module and SQLite link successfully |
| Project regeneration | Deterministic; Python standard library only |
| Swift and source layout | App and package files remain under the repository's 500-line constraint |

The HTTP fixture binds only to `127.0.0.1`, uses a synthetic key and records synthetic messages. It never runs an agent, model, shell command or real approval. Its tests exercise the HTTP/SSE adapter, not the native setup UI or Keychain.

The streaming test caught a real boundary issue: Foundation's async line reader dropped blank lines in the fixture stream, so the implementation now decodes bytes and retains SSE event boundaries. The regression covers blank lines, multiline data, CRLF and UTF-8. A broken stream produces an interrupted turn rather than a fabricated completed reply.

## Remaining acceptance work

The build Mac has the iOS simulator SDK but no installed runtime. A separate Mac with an installed iOS 18.3 runtime launched the built app in a dedicated simulator and captured the actual native views with isolated sample content. [Native screenshots and reproduction](screenshots/SCREENSHOTS.md) record this layout verification. Keyboard behavior, Dynamic Type, VoiceOver, Keychain save/rollback, foreground/background transitions and multi-device approval races still require simulator or device acceptance. No physical iPhone or TestFlight release has been verified.

The initial app stores conversation snapshots in SQLite. Full-text search, paged local histories, background push, shared roster metadata and the remaining full-feature UI remain later milestones. An interrupted turn without authoritative run readback remains unconfirmed and is never blindly resent.

## Reproduce

From a Mac checkout of this repository:

```bash
./scripts/build-ios.sh -quiet
./scripts/test-ios-core.sh
swift test
SWARMHUB_FORCE_SWIFTC=1 ./scripts/build.sh
```

To inspect the app, install an iOS 18-or-newer simulator runtime through Xcode, select the **SwarmHub** scheme in `Apps/iOS/SwarmHub.xcodeproj`, and Run. The explicit local demo requires no server or credentials. A real iPhone requires the user's signing team selected in Xcode.
