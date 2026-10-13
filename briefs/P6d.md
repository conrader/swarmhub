# P6d — Headless UI snapshot with the real store

Read `PLAN.md`; standing constraints apply. Start from `main`. Branch `p6d`.
Goal: prove the real UI renders Konrad's imported bots and Grok history, without launching the GUI or driving the desktop.

1. Add `AgentApp --render-snapshot <dir> [--bot "<name>"]...` (headless): load the real store exactly as the app does,
   then render with SwiftUI `ImageRenderer` (scale 2, dark appearance, 1280×800) and write PNGs:
   `main.png` (full ContentView with sidebar and the first Grok bot selected), and per `--bot` a PNG with that bot
   selected and its "Imported from Grok Bot" history section EXPANDED, plus `info-<bot>.png` of its right panel.
   If some views need a window/NSApp to render, use an offscreen `NSHostingView` + `cacheDisplay(in:to:)` instead.
   Never write snapshots inside the repo. Unit test: the command renders a synthetic store to non-empty PNGs.
2. Build + `swift test` green; package + reinstall (signed, same backup rule).
3. Run it with the installed binary into `~/Library/Caches/Torvli-snapshots/` (0700) for `--bot Jarvis --bot Infra`
   and report each PNG's path and pixel size. Do not open, upload or copy the images elsewhere.
4. Commit on `p6d` (author Konrad Sierzputowski <konrad@dmt.zone>); no push.
