# Native iOS screenshots

Captured on 14 October 2026 from the SwiftUI app in `Apps/iOS`, based on the native foundation at [1388237](https://github.com/conrader/swarmhub/commit/1388237) plus the capture configuration included with these images.

The eight individual PNGs show **Chats, Conversation, Approvals and Settings** in dark and light appearances. They are actual, unedited simulator captures at 1206×2622 pixels, from an iPhone 16 Pro running iOS 18.3. The Debug simulator app was built with Xcode 27.0 / Swift 6.4 and an iOS 18.0 deployment target. A separate Mac with the iOS 18.3 runtime ran the app through `simctl`.

All agents, messages and approval requests are synthetic. Debug-only `--capture-screen` and `--capture-appearance` flags seed in-memory demo clients and select a native destination. This path skips SQLite initialization and never reads or writes credentials or contacts a server. The sample approval cannot grant a real action. Release builds ignore the capture flags.

The README images, `mobile-dark.png` and `mobile-light.png`, arrange these captures using [contact-sheet.html](contact-sheet.html). The surrounding phone frames and captions are HTML/CSS; the screen contents are the original native PNGs. The website uses the individual PNGs. The separate [screen drawings](../screens.html) show the broader future feature target. All images here are iOS; Android remains at the planning stage.

## Capture on a Mac

Build the Debug simulator app, then create a dedicated simulator using an installed iOS 18-or-newer runtime. Use the simulator UUID returned by `simctl create`:

```bash
./scripts/build-ios.sh -quiet
xcrun simctl create 'SwarmHub Captures' com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-18-3
xcrun simctl boot <simulator-uuid>
xcrun simctl bootstatus <simulator-uuid> -b
SWARMHUB_CAPTURE_DEVICE=<simulator-uuid> ./scripts/capture-ios-screenshots.sh
xcrun simctl shutdown <simulator-uuid>
```

Replace the runtime identifier with an installed version if necessary. The capture script terminates only SwarmHub on the supplied simulator, installs the Debug app, sets its screenshot status bar, switches the simulator appearance and captures all eight screens. Use a dedicated simulator because these settings are changed. It terminates the app after capture; shut down the simulator when finished.

`SWARMHUB_SIMCTL`, `SWARMHUB_CAPTURE_APP` and `SWARMHUB_CAPTURE_OUTPUT` can override the tool, built app and output paths. This supports building on one Mac and copying the `.app` to another Mac with an installed simulator runtime. On the capture Mac, the tool was `/Applications/Xcode-16.2.0.app/Contents/Developer/usr/bin/simctl`.

To rebuild the contact sheets, serve the repository locally and open `docs/ios/screenshots/contact-sheet.html?theme=dark` and `?theme=light` at a 1480 px viewport. After all images load, capture the `main` element at device scale 1. Inspect both sheets and the eight source captures before publishing.
