# SwarmHub native iOS verification

14 October 2026 · Native foundation implementation

The iPhone app is in `Apps/iOS`, with shared code in `Packages/SwarmHubCore`. Verification used a separate development checkout on the Mac. No installed desktop app was replaced, no personal server was contacted, and no production Keychain or conversation data was used.

| Check | Result |
| --- | --- |
| Xcode simulator SDK build | Passed with Xcode 27.0 / Swift 6.4, deployment target iOS 18.0 |
| Simulator binary architectures | `arm64` and `x86_64` |
| Bundle identifier | `com.konrad.swarmhub.ios` |
| Shared unit and real-HTTP fixture suite | 20 tests passed, including profile isolation, canonical history, streaming, manual approval acknowledgment, Stop, steer transport and interrupted-stream handling |
| Desktop regression suite | 436 tests passed after extracting the shared text encoder and incorporating the latest group-document changes |
| Desktop direct-compiler fallback | Passed with `SWARMHUB_FORCE_SWIFTC=1`; shared module and SQLite link successfully |
| Project regeneration | Deterministic; Python standard library only |
| Swift and source layout | App and package files remain under the repository's 500-line constraint |

The HTTP fixture binds only to `127.0.0.1`, uses a synthetic key and records synthetic messages. It never runs an agent, model, shell command or real approval. Its tests exercise the HTTP/SSE adapter, not the native setup UI or Keychain.

The streaming test caught a real boundary issue: Foundation's async line reader dropped blank lines in the fixture stream, so the implementation now decodes bytes and retains SSE event boundaries. The regression covers blank lines, multiline data, CRLF and UTF-8. A broken stream produces an interrupted turn rather than a fabricated completed reply.

## Remaining acceptance work

The Mac has the iOS simulator SDK but no installed simulator runtime or available simulator device. The app was compiled and linked; it was not launched in a simulator or on an iPhone. Native screen layout, keyboard behavior, Dynamic Type, VoiceOver, Keychain save/rollback, foreground/background transitions and multi-device approval races still require simulator or device acceptance. No native screenshots or TestFlight release are claimed.

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
