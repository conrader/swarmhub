# Agent QA on a Mac

Run the installed SwarmHub executable over a terminal or SSH on a Mac with a desktop session. The app uses its native chat actions, SwiftUI views, sample messages and a local mock reply. The renderer opens an offscreen window. Each invocation starts a fresh sample workspace and creates its own output directory.

```sh
app=/Applications/SwarmHub.app/Contents/MacOS/AgentApp
"$app" --agent-qa /tmp/swarmhub-qa --hunt
```

For command help from the installed binary, run `"$app" --agent-qa --help`.

The built-in exploration checks per-chat drafts, delivery, unread counts and pins, then captures the workspace and release notes in a set of window states. Read the final JSON event for the report path. A failed expectation produces an observed value, a screenshot and a nonzero process exit. The report distinguishes failed checks from observations recorded by the agent.

## Drive a session

Omit `--hunt` to send one JSON object per line on standard input. Wait for the `ready` event, send an action, read its result, and choose the next action using the returned state. Close stdin to finish and write the report. All request fields use strings.

| Action | Fields | Result |
| --- | --- | --- |
| `inspect` | | Names, unread counts and pins, selected chat, draft and messages, current screen and viewport |
| `open` | `bot` | Open a sample chat by the name in state |
| `draft` | `text` | Type or clear the selected chat’s draft |
| `send` | Optional `text` | Submit the text or current draft and wait for the local reply |
| `pin`, `unpin` | | Pin or unpin the selected chat |
| `appearance` | `value` = `light` or `dark` | Choose appearance for captures |
| `viewport` | `width`, `height` | Set window dimensions in points, from 980 × 620 to 2560 × 1600 |
| `details` | `value` = `show` or `hide` | Show or hide chat details |
| `screen` | `value` = `workspace` or `whatsNew` | Choose the native workspace or release notes pane for capture |
| `capture` | | Save a PNG of the current screen and return its filename |
| `expect` | `field`, `value` | Compare selected chat (`selected`), `draft`, `pinned`, `unread` or `lastRole`. For `contains`, also pass `text` and expect `true` or `false` |
| `finding` | `kind` = `bug` or `improvement`, plus `text` | Save an observation with its step number and screenshot |

For an exploratory review, inspect a compact window in both appearances, compare it with a larger window, and open the PNGs. Look for clipped controls, unreadable text, ambiguous actions and state that leaks between bots. Record what you saw and the expected behavior. Keep a visual observation labelled as such when you have only reproduced it in the offscreen renderer. Provider behavior, macOS dialogs and physical mouse or keyboard events require a separate live test.

```sh
"$app" --agent-qa /tmp/swarmhub-qa <<'JSONL'
{"action":"open","bot":"Mira"}
{"action":"draft","text":"Review the release"}
{"action":"open","bot":"Patch"}
{"action":"expect","field":"draft","value":""}
{"action":"capture"}
JSONL
```

Replay a run with `"$app" --agent-qa /tmp/swarmhub-replay < /path/to/run/replay.jsonl`. For one finding, pipe the first lines of the replay through its recorded step number. Compare the new state and screenshots to the original. Invalid commands return an error event and count separately from failed checks. Agent-reported suggestions alone leave the exit code at zero.

## Details inspector screenshots on mini-m4

On mini-m4, use a logged-in desktop session and a checkout containing the 0.8.16 inspector commit. From its repository root, run this block in zsh. It builds the debug executable from that checkout and renders both appearances from the synthetic HeadlessHerdrShots store. Allow the Herdr fixture set to finish in each appearance.

```sh
(
  set -eu
  SWARMHUB_BUILD_CONFIGURATION=debug ./scripts/build.sh
  app="$(cat .build/agentapp-bin-path)/AgentApp"
  shots="$(mktemp -d /tmp/swarmhub-details.XXXXXX)"
  "$app" --render-setup "$shots/dark" --only herdr
  "$app" --render-setup "$shots/light" --only herdr --light
  for mode in dark light; do
    for shot in herdr-model-tab herdr-model-tab-narrow herdr-model-no-list herdr-model-overview herdr-routines-details herdr-skills-details herdr-media-details; do
      test -s "$shots/$mode/$shot.png"
    done
    sips -g pixelWidth -g pixelHeight "$shots/$mode/herdr-model-tab"{,-narrow}.png
  done
  open "$shots"
)
```

Compare `herdr-model-tab.png` (360 × 800 pt, 720 × 1600 px) with `herdr-model-tab-narrow.png` (300 × 800 pt, 600 × 1600 px). Claude carries the Default label. Codex carries the checkmark and uses Server model B. The helper uses Claude with Server model A. Auto is on for new sessions, and the separate reviewer line describes the running session. The no-list fixture shows a program that chooses its own model and Auto off. The other four tabs show the bot’s identity, a routine retry with the fixture’s keyless server, a skill list and a chat link.

For keyboard, contrast and VoiceOver QA, use the running app on the Mac. Open a test Herdr bot’s Details, drag the column to its minimum width and enable Keyboard navigation in System Settings → Keyboard. Tab through the header, program rows, model menus, Auto switch and Advanced disclosure. Use Space to activate a row or switch and the arrow keys and Return in a menu. With VoiceOver (Command-F5), check the selected tab, the checked program, the Default label and the switch’s name and value. In System Settings → Accessibility → Display, turn on Increase contrast and check the focus ring, row borders, checkmark and secondary text in both appearances.

## Concurrent chat responsiveness on mini-m4

From the candidate worktree in a logged-in desktop session, with the display awake, Reduce Motion off, and Screen Recording access for the test host, run the comparison script.

```sh
./scripts/compare-responsiveness.sh
```

The runner uses the local Sparkle 2.10.0 binary from the app build. For a different cache location, set `SPARKLE_XCFRAMEWORK` to the full path of that xcframework. It builds baseline `7306c60c` and the candidate in separate directories under `out/responsiveness.*` with the same release flags and the same probe. Leave its window in the foreground. Each measurement starts a fresh test process with its own synthetic store, defaults, in-memory keys and scripted backends. Production launch work and update checks never start.

Each run shows the real sidebar and chat with four animated bot marks, a chat-header mark, and 96 seeded rows per chat. One or four bots each produce 800 paced text events at 10 ms intervals, including full draft replacements, interleaved with eight tool starts and finishes. The probe scripts 24 mouse clicks between two sidebar rows while the requested number of turns is running. Both configurations run twice, reversing order on the second pass. The runner checks the focused regression tests before timing either build.

Read each run's JSON separately. `click_to_visible_chat` measures from the off-main submission of an in-process mouse click to the WindowServer display timestamp of the first captured frame containing the destination chat title. The probe calibrates against both rendered titles and waits for each visible switch. This includes main-thread queueing and excludes physical mouse and panel scanout delays. `main_queue_wait_proxy` ends when the main actor starts dispatching the click. `window_frame_gaps` measures the intervals between complete ScreenCaptureKit frames of the animated window during the clicks, sampled at up to 60 Hz. Capture can miss intermediate frames. Each distribution includes raw milliseconds, nearest-rank p95, maximum, and counts above 33.4, 50 and 100 ms. A missing title, an inactive window or a switch timeout fails the run.

The baseline stream consumer publishes the entire store once per text event, in addition to publishing the reply and typing timestamp. At the fixture's four-stream input rate that path alone issues 400 store broadcasts per second. The selected chat rebuilds its message order and the sidebar walks and sorts conversation histories on store invalidation. Only the selected transcript is mounted. The kit already uses one display clock for all live avatar canvases. Compare `store_broadcasts`, avatar frames and draw costs alongside latency. Periodic snapshots still encode and write the full store on the main actor, with the same two-second autosave interval in both builds.

## Use the real Mac window

Launch a second instance with a disposable sample workspace, five local mock bots and a 486-message conversation saved halfway through. Mouse, keyboard and accessibility tools interact with the regular SwarmHub window. Sample conversations and draft replies last for the life of the process. Use a test macOS account when exercising system dialogs, global preferences, clipboard actions or integrations.

```sh
/Applications/SwarmHub.app/Contents/MacOS/AgentApp --agent-qa-window &
qa_pid=$!
python3 Tests/Scripts/chat-window-smoke.py "$qa_pid"
```

The smoke test requires PyObjC’s ApplicationServices module and macOS Accessibility access. It measures text inside the window as it restores the saved message, jumps to the end and switches between bots. Run it against a freshly opened sample window. Quit that instance to discard the session.

To measure switching through a larger roster, use an app built in Release configuration and a logged-in Mac with Accessibility access.

```sh
/usr/bin/python3 Tests/Scripts/chat-switch-latency.py /Applications/SwarmHub.app /tmp/chat-switches.json
```

The driver opens a disposable workspace with 50 idle bots and 96 messages per bot. It uses the Next Chat shortcut to visit the entire roster four times. Each timer stops when the last message of the destination chat is exposed by Accessibility and intersects the scroll viewport. During each pass the driver edits one chat’s draft, checks the adjacent composer is empty, and on the next visit verifies the original draft. The JSON includes all 200 timings and 12 stationary observations of the same row. Run both builds on the same Mac in alternating order. These numbers measure native Accessibility response. Use the streaming benchmark above for captured frame timings.

To check whether a long group chat survives a restart, run the same driver with a packaged app.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --group-restart /Applications/SwarmHub.app
```

The driver copies the app to a temporary directory, gives it a private bundle identifier and seeds a temporary home with a 620-message group. It opens the saved middle message, jumps to the end, quits, reopens, pages back and quits again. The final launch checks that the earlier page is visible. The script also checks every saved message ID.

To check saved-message search on the Mac, run the driver against the candidate app.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --message-search /Applications/SwarmHub.app
```

The driver opens a private workspace with 800 live messages and 1,000 imported Grok entries. It checks the visible message after a click, Return and keyboard navigation. It pages through neighboring imported messages, switches conversations, relaunches the app and opens a chat whose archive file has gone away. Set `SWARMHUB_QA_LARGE_HISTORY=1` on the same command to repeat the exercise with 33,000 imported entries (about 32 MB). The driver reports time to a result and time from selection to the visible message.

To check the order of replies after steering a bot and reopening SwarmHub, use the native window driver.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --steer-reopen /Applications/SwarmHub.app
```

The driver opens two private chats with a loopback workspace offline. One saved turn has just acknowledged the follow-up. In the other, the bot has already started its next step. It types a draft in a third chat and brings the workspace online. Both recovering bots must become unread, including the pinned bot, while the draft retains its text and keyboard focus. The driver opens a coding helper, returns to its parent chat, and checks which badge clears. A second offline launch verifies the remaining unread badge and the order of both answers beneath their guidance. The same fixture reopens a group whose stop request had no confirmed outcome, then verifies the group’s recovered final answer, its original row and its unread status.

To exercise cross-chat navigation and watch a working bot finish in Activity, run the window driver with its private chats.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --activity /Applications/SwarmHub.app
```

To test keyboard decisions inside Activity, run the companion check with a private workspace.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --activity-decisions /Applications/SwarmHub.app
```

It presents two current permission requests and one from an old session. The driver inspects each current request’s arguments and records which request ID and decision the server receives.

The navigation check opens an unread group from Activity, returns to an existing draft, sends it, and watches that bot move from working to unread. Selecting the answer clears its entry. A second selection opens an incomplete reply that still needs attention.

To check the Team inspector and Team Pack sharing in both appearances, run the native window driver.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --team /Applications/SwarmHub.app
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --team-pack /Applications/SwarmHub.app
```

The driver opens the handoff, checks that another bot has its own activity, then closes and immediately reopens Details. It also checks the rightmost controls at the minimum window size. The Team Pack check saves a two-bot group through the macOS file dialog, opens the JSON from New Group, checks that the preview leaves the store untouched and then verifies the imported group and its new bots.

To check replies that arrive while the selected chat is out of view, run the native window driver.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --window-unread /Applications/SwarmHub.app
```

The driver sends a message to a private bot and group in each of five conditions. It minimizes the workspace, hides SwarmHub, switches to Finder, opens Settings and opens Search. It verifies that each reply finishes with one unread mark and that returning to the workspace clears it.

To check published media in a bot reply, run the driver from a checkout containing the PNG and MP4 fixtures.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --media-reopen /Applications/SwarmHub.app
```

It opens the image and plays the clip in the real chat, takes the fixture server offline, switches chats and relaunches the app. The check passes when the previews still work and each file was downloaded once.

To check an AI installed after setup, use a Mac workspace service that supports the `add-ai` command.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --ai-inventory /Applications/SwarmHub.app ~/.local/bin/swarmhub-herdr
```

The driver opens a bot’s model settings and adds a fixture Antigravity executable to the private home’s search path. It presses **Scan again** and **Add Antigravity CLI** while a loopback workspace is offline. After the workspace comes back, the driver verifies the registration, selects Antigravity in the open bot picker, and checks the saved per-bot preference. A marker detects accidental execution of the fixture CLI.

To verify native Page search, pass a packaged app and the workspace executable for this Mac.

```sh
/usr/bin/python3 Tests/Scripts/chat-window-smoke.py --pages /Applications/SwarmHub.app /path/to/swarmhub-herdr
```

The driver starts a private loopback workspace, edits a published Page and opens its original revision from chat search. It checks the latest revision, a second Page found by its body, punctuation in a query and local navigation after disconnecting the workspace.

The Page draft check runs a private workspace and Herdr Core with a scripted CLI. It sends a request through the Mac chat window, asks for a shorter draft, approves the returned revision, and reopens the app to verify both decisions.

```sh
/usr/bin/python3 Tests/Scripts/page-draft-window.py /Applications/SwarmHub.app /path/to/swarmhub-herdr /path/to/herdr-core
```

To check terminal scaling, run the private window against a real workspace and Herdr Core. The driver opens the preview from a bot’s chat header, moves the native divider, waits for new output on the last terminal row, restores the panel width and verifies the original process geometry.

```sh
/usr/bin/python3 Tests/Scripts/terminal-preview-window.py /Applications/SwarmHub.app /path/to/swarmhub-herdr /path/to/herdr-core
```
