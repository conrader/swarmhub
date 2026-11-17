# iPhone app: starting material

This folder is not an app and does not build. It holds the parts of an earlier SwarmHub iPhone app that do not depend on the server that app was written for, kept as a starting point for an iPhone app that talks to Herdr.

There is no Xcode project, no app entry point and no networking here.

## What is here

| Path | What it is |
| --- | --- |
| `Sources/DesignSystem.swift` | Three SwiftUI views: the two-eyed agent mark in four colours, an information note, and an empty-state view. SwiftUI only. |
| `Sources/KeychainCredentials.swift` | Read, write and remove one secret per account name in the iPhone Keychain (this device only, available when unlocked). Foundation and Security only. Its service name is `com.konrad.swarmhub.ios.backends`; choose the new app's own before shipping. |
| `Resources/Assets.xcassets` | The asset catalog with the 1024 px app icon. `scripts/render-app-icon.py` regenerates the icon from the Mac logo. |
| `assets/readme-hero.svg`, `assets/readme-hero-mobile.svg` | The header art of the earlier app's README. The tagline names what that app did ("Conversations, sessions and approvals"); change it before use. The same script refreshes the logo inside them. |
| `design/screens.html` | 37 screen drawings in the browser, light and dark, with sample content. Open the file; it needs no server. Sources: `ui.js`, `prototype.js`, `screens-core.js`, `screens-work.js`, `screens-settings.js`, `screens.css`. |
| `design/screen-map.md` | Every drawing with its purpose and where it leads. |
| `design/design-notes.md` | Navigation, interaction and visual rules the drawings follow. |
| `design/core-screens.png`, `design/work-screens.png` | Two boards of six drawings each, captured from `screens.html` (`#board-core`, `#board-work`) at 1440 px. |
| `design/screenshots/mobile-dark.png`, `mobile-light.png` | The earlier app running in an iPhone simulator: Chats, Conversation, Approvals, Settings. They show how `DesignSystem.swift` looks in a real build. |

The two Swift files were compiled as part of the earlier app (Xcode 27, Swift 6.4, iOS 18). They have not been compiled on their own since.

## Read the drawings as layouts

The drawings were made in October 2026 for a different server model. Many screens show things Herdr and the Mac app do not have: profiles with one key each, routines, an approval inbox and policies, a manager agent, usage totals, a hosted setup. Use them for layout, navigation and tone. What an iPhone app for Herdr shows should follow the Mac app (`Sources/AgentApp`) and the bridge (`HerdrWorkspace/`), not these screens.

The parts of the drawings that named the old server and listed its requirements were removed.

## What was removed, and why

The earlier app was a client for a server SwarmHub no longer supports. Every screen (setup, conversation picker, chat, approvals, device approvals, settings) and its store were written against that server through the `SwarmHubCore` package, so none of it could be kept without it. Removed with it:

- the app's other Swift sources, its Xcode project, tests and fixture server (was `Apps/iOS`);
- the two Swift packages only it used (was `Packages/SwarmHubCore`, `Packages/SwarmHubCoordination`);
- its specification, verification notes and individual screenshots (was `docs/ios`);
- the scripts that built, tested and captured it.

All of it is in git history, unchanged since commit `65f50cc` on the `herdr-workspace` branch. `git show 65f50cc:Apps/iOS/Sources/ChatView.swift` prints a file, and `git checkout 65f50cc -- Apps/iOS Packages docs/ios` brings the folders back.

## What an iPhone app for Herdr needs first

1. **A way for the phone to reach the bridge.** Today it cannot. The bridge listens on `127.0.0.1` of the machine it runs on and refuses requests addressed to any other host name. The Mac app reaches a remote server by forwarding that port over SSH, which an iPhone app cannot do on its own. Someone has to decide how a phone gets in (for example a private network such as a VPN between phone and server, or an HTTPS address in front of the bridge with its own sign-in) and what that means for the access key. This is a product and security decision, not a coding task.
2. **A Swift client for the bridge.** The Mac app has one (`Sources/AgentApp/Backends`, the `Herdr*` files). It is part of the Mac target, which uses AppKit, so the files that only need Foundation would have to move into a package both apps use.
3. **A new Xcode project** with its own bundle identifier and signing.

The bridge also serves a browser workspace that can be added to an iPhone's Home Screen ([HerdrWorkspace/README.md](../../HerdrWorkspace/README.md)). It has the same limit: the phone must first be able to reach the bridge.
