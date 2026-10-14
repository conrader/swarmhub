# SwarmHub for iOS

The native iPhone application lives in this repository alongside the macOS application. It requires iOS 18 or later and an Xcode version with the iOS 18 SDK or newer.

The first implementation includes server/profile setup, profile-isolation checks, Keychain credentials, server-session selection and creation, SQLite history/drafts, streaming text chat, Stop when supported, and manual approvals from live turns. A clearly labelled local demo lets you inspect the navigation without connecting an agent.

The [full iOS specification](../../docs/ios/specsheet.md) and [37 screen drawings](../../docs/ios/README.md) define the remaining features. Groups, attachments, routines, remote computers, model selection, connected apps, imports, manager-agent controls, shared metadata and closed-app notifications are subsequent milestones. Android follows the shared wire contract; its native target has not been added yet.

## Build and run

Open `Apps/iOS/SwarmHub.xcodeproj` in Xcode, select the **SwarmHub** scheme and an installed iPhone simulator, and Run. For a physical iPhone, select your development team in Signing & Capabilities and use Xcode to install the app. No signing identity or team is stored in the project.

To compile an unsigned simulator app from the repository root:

```bash
./scripts/build-ios.sh
```

The app is written to `Apps/iOS/build/Build/Products/Debug-iphonesimulator/SwarmHub.app`. Compiling against the simulator SDK does not require an installed simulator runtime; launching and UI verification do. Use `SWARMHUB_IOS_CONFIGURATION=Release` to check Release or `SWARMHUB_IOS_SDK=iphoneos SWARMHUB_IOS_DESTINATION='generic/platform=iOS'` for an unsigned device build.

The checked-in project is generated with `python3 scripts/generate-ios-project.py`, which uses only the Python standard library. Run it after adding or removing source files. Xcode resolves the repository-local `Packages/SwarmHubCore` dependency; no third-party iOS dependency is downloaded.

## Connect an existing Hermes server

1. Choose **Connect my server**, enter its HTTPS address, profile name and that profile's key, then **Test connection**.
2. Review the verified profile and choose **Add agent**. Test alone saves no key or profile. Add additional profiles from Settings or the plus button in Chats.
3. Open the agent and choose an existing server conversation or create a new one. Choosing the same server session as desktop shares that session's transcript; the clients do not yet share roster bindings, reactions or preferences.
4. Send a text message. Stream progress and run identity are cached. A lost connection remains interrupted until the server confirms a terminal state; the application does not automatically resend.

The first implementation requires the server's `session_chat_streaming` capability for native chat. Reachable legacy servers can be verified but cannot chat in this build. Features are selected from reported capabilities and route results, not a version number. Remote addresses require HTTPS; localhost on iPhone is the phone, not the Mac. No custom Hermes routes, patched agent or installed server skill are required.

Approvals are manual. Only a request with an exact, unredacted action and an offered `once` choice can be approved. Decisions stay pending until the server acknowledges a nonzero resolved count. Uncertain delivery blocks another decision until an explicit status check; display-only actions stay unavailable. A full pending-request inbox and cross-device audit still need additional implementation.

Leaving the app closes its local stream without sending Stop. On reopening a known session, history and any cached run are checked. If the server cannot report an interrupted run or the client never received its run ID, the turn stays unconfirmed. Cached history remains readable; SQLite currently stores transactional conversation snapshots, with indexed/paged local history and search planned.

## Tests and verification

Run the shared core's unit and real-HTTP fixture tests on a Mac:

```bash
./scripts/test-ios-core.sh
```

The script launches a dependency-free Python fixture bound only to `127.0.0.1`, runs the Swift package tests, then stops the fixture. All keys, conversations and commands are synthetic. It never contacts a personal Hermes server, writes to a real Keychain or starts an agent/model/tool. Plain `swift test --package-path Packages/SwarmHubCore` runs unit tests and skips the optional HTTP fixture suite.

The desktop application imports `SwarmHubCore` for the same text splitting and request-size checks. Run its regression suite separately with `swift test` from the repository root.

See [native verification](../../docs/ios/native-verification.md) for the checked build/test results and remaining device checks. The SVG/HTML screen drawings are design references, not screenshots of the native app.
