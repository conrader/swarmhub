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
