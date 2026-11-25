# SwarmHub Mac interaction audit · 25 November 2026

## Reproduced in the interface

| Finding | Reproduction | Verified result |
| --- | --- | --- |
| Restoring a long chat could show an empty transcript | On the installed 0.8.16 MacBook app, open GameDev and then Infra. The header and composer appeared. The transcript’s accessibility viewport contained zero visible text runs. The local store contained 227 entries and a valid saved anchor. | In the patched native window, a 486-message fixture opened on saved message 243. Jump brought message 486 onscreen within 0.17 seconds after the button press in the recorded smoke test. Twelve further bot switches each restored the same visible row in 0.21–0.24 seconds, including the test driver's time. |
| Reply quotes followed the user into another bot | Click Reply in Patch, then open Mira. Mira’s composer displayed Patch’s quote. | The other conversation has no quote. Returning to the original bot restores its pending quote. Group reply drafts also have their own conversation ID. |
| Creating a sample group was a dead end | In a sample-only workspace, click New group with Patch. The sheet required two bots, exposed one checkbox and disabled Create. | The sheet offered five sample bots. Selected Mira, created a group, sent an @Mira message and observed a local reply. |
| Videos appeared as ordinary files in Media | Send a PNG and an MP4 through the macOS Open panel. The MP4 played inside chat and appeared as File in Media. | The PNG opened a preview, the MP4’s inline player switched to playing, and Media listed them as Image and Video. |
| The composer exposed its send arrow as “Up” | Inspect the idle composer using macOS Accessibility. | The send control now exposes “Send message”. The attachment picker also names video in its help. |

The ten-second jump reported by the user did not recur in the recorded installed-build run. Jump recovered the Infra viewport on that attempt. The timings above measure a synthetic conversation in a debug build. They are observations from this MacBook, not a production performance benchmark.

## Other exercised paths

- Selected each Details tab on a live Herdr bot. Closed Details, and reopened it through the bot name on 0.8.16. Verified the explicit Details button is available after closing the panel on the candidate.
- Visited all seven Settings panes through the installed app’s sidebar. Servers showed Claude, Codex and Gemini. AIs offered Scan again. The exercise covered navigation and discovery.
- Typed a draft, changed bots, returned to the first draft and sent it. Checked for the mock assistant’s completed text as well as a cleared composer.
- Used the native search sheet to filter for Mira and open its chat. Used a physical-style scroll-wheel event to move from the page starting at message 463 into the preceding history. Checked the visible text before and after.
- Ran the existing 29-step mock hunt for drafts, unread state, pins, appearance, compact layout and release notes. It passed all of its expectations on the installed build, which also reproduced the empty Infra transcript. This prompted the addition of a native-window smoke test that checks rendered text at screen coordinates. [Run the native test](agent-qa.md#use-the-real-mac-window)

## Product comparison and remaining checks

- In OpenBot’s interactive preview, switching from Atlas to Forge changed the header’s model control from Claude Opus 5.5 to GPT-6 Luna and exposed its reasoning level. A useful SwarmHub improvement would make the header model open this bot’s model settings and show any pending change beside the active model. [OpenBot preview](https://openbot.run/app-preview)
- Measure how quickly a bot acknowledges a status question or change of direction while its helper runs a build. Verify receipt by the active turn and check that its background job continues exactly once. OpenBot describes queued messages for a busy agent. A matched live test would establish whether SwarmHub responds faster. [OpenBot product description](https://openbot.run/)
- Pending end-to-end coverage includes real-provider steering and model handoff, reopening a saved production-scale group after restart, completing setup with a CLI update prompt, the update installer, and remote or disconnected servers. Read-only visits to Settings do not exercise credential changes or install software.
