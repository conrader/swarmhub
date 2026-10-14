# README screenshots

Captured on 2026-10-14 from the current SwarmHub SwiftUI interface. The UI source is [a3d668d](https://github.com/conrader/swarmhub/commit/a3d668d); the screenshot renderer fix in this update preserves the content of both glass panes.

- `swarmhub-dark.png` and `swarmhub-light.png`: 1440 × 900 points at 2× resolution (2880 × 1800 pixels).
- Content: mock agents, explicitly configured BotAvatarsKit marks, a sample group, and a sample draft. The store and preferences are isolated; no saved conversations or configured servers are used.
- Source: [capture fixture](capture-fixture.swift), using the same `ContentView`, `SidebarView`, chat cards, and `InfoPanel` as the app.
- `docs/screenshot.png` and `docs/screenshot-dark.png` retain the dark capture for older documentation links.

## Regenerate on a Mac

Use a clean development checkout so the temporary capture test is separate from other work:

```bash
cp docs/readme/capture-fixture.swift Tests/AgentAppTests/ReadmeScreenshotTests.swift
SWARMHUB_README_OUTPUT="$PWD/docs/readme" swift test --filter captureCurrentSwarmHubReadme
rm Tests/AgentAppTests/ReadmeScreenshotTests.swift
cp docs/readme/swarmhub-dark.png docs/screenshot.png
cp docs/readme/swarmhub-dark.png docs/screenshot-dark.png
```

Inspect both captures and update the capture date and source commit before publishing them. The README selects the image for the reader’s light or dark appearance.
