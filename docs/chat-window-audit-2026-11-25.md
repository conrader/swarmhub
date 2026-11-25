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

## Live Codex steering on the MacBook

A temporary Codex session started one uniquely timed sleep command. While that process was running, the test sent a fresh word through the same authenticated steering endpoint SwarmHub uses. The endpoint acknowledged it in 14 ms. The command ran once and the session produced one final reply containing the new word. The test ended the temporary session. The 14 ms measures receipt at the endpoint. It excludes the time to produce the reply.

The bridge reported zero tool activity throughout the command. The reply footer now omits the count when the app has no observed calls. Codex’s saved turn contained a completed command with an exit code, which the bridge’s live listener had ignored.

On a second pass with the patched bridge and a private Core and workspace on the MacBook, a real Codex command appeared in the draft’s activity while it ran. The same activity ID changed to finished, followed by a single final reply. This passed both after skipping untrusted hooks in an unprepared test workspace and with the normal setup preparation in a new workspace. No changes to the installed bridge were needed. A final pass connected the native QA app to the private workspace. Through macOS Accessibility, the driver typed a request, pressed **Send message**, waited until the command was running, then typed a fresh word and pressed **Send into the current answer**. The composer cleared after each press. The running command was visible in the interface. The same command ran once, the final reply matched the new word, and the native reply footer read “37 s · 1 tool call”. The temporary app used the regular composer and transport with an isolated bot, preferences and server. This scenario covered a command in the bot’s own turn. Other providers still need separate coverage.

## Chat during a separate helper build

In the first private Mac run, the parent requested a separate compiler helper and then ran `helper wait`. Both the start receipt and the standing helper instructions suggested waiting. In manual mode the start, wait and compiler commands also requested approval. The helper produced the executable, but the parent was still working after it said “STARTED”.

With the candidate and Auto mode enabled for the test bot, the native chat sent the build to one helper. The parent returned “STARTED” and finished its turn. The launch records showed GPT-6.2 Astra for the parent and GPT-6.2 Sol for the compiler helper. The helper built and ran an ARM64 C executable. A controlled 30-second delay kept its final build step observable. During that step a fresh, independent message in the native composer reached the parent. Its reply appeared 3.91 seconds after the composer cleared, while the helper process was still running.

The helper’s answer appeared in the parent chat’s Coding agents card without another message. When its terminal closed, the card kept the result. Pressing Details opened the answer. The workspace recorded one helper and zero workspace approval requests during that run. This exercise covered a direct chat and a helper on the same Mac. It did not measure remote worker latency. A separate follow-up exercise is recorded below.

## Continuing after a helper finishes

In an isolated native MacBook chat, the user asked the parent to start a helper, reply “STARTED”, then write the helper’s UUID to a file and report back. The helper slept for 15 seconds and generated the UUID itself. On the baseline the helper answered and the parent stayed idle. After another 40 seconds there was no file or follow-up reply.

On the first candidate the parent tried the new command, but its terminal resolved an older workspace executable on its PATH. The start receipt now supplies the running workspace’s quoted executable path. With the corrected candidate, the parent registered its next step and finished its turn. When the helper answered, the parent wrote the UUID to `verified.txt` and the matching “VERIFIED” reply appeared in the native chat without another user message.

In a second run, the driver sent an independent user request just after “STARTED”. The helper finished while the parent was executing the requested 35-second foreground command. The workspace delivered the helper outcome after the independent reply appeared. The parent then completed the saved next step, and both the file and the chat contained the new UUID. These runs used a local registered Codex bot in Auto mode.

## Detecting an AI added after setup

The installed MacBook service reported Claude, Codex and Antigravity. Its executable scan found Antigravity’s `agy` and did not find the separate `gemini` executable.

In an isolated native wizard, the first candidate showed Codex as installed yet launched `codex app-server` to fetch its models during discovery. The same run found that Settings wrote the new Antigravity template, then reported an access-key error while validating it against the default port. The test service used a different port.

On the fixed candidate, a macOS Accessibility driver opened the wizard against a private workspace. An instrumented Codex executable reported an update notice if launched. The wizard displayed Codex as installed. After the first scan, the driver placed a Gemini executable in the test path, pressed **Scan again**, then **Add Gemini CLI**. The invocation log stayed empty through all three steps. **Create a bot** offered both programs. Only on the model selection screen did the selected Codex provider receive its model-list command, with startup update checks disabled.

A second run began with zero registered templates and reached the bot picker with Gemini alone. In Settings, the driver added an Antigravity executable after opening **AIs**, rescanned and chose **Add Antigravity CLI**. Settings confirmed registration on the workspace’s actual port. The test used the real Mac app, bridge and Core, with disposable provider executables. It covers discovery and registration. Signing in to Gemini or Antigravity and completing a chat require separate tests.

## Switching between Codex and Claude in the same chat

On the MacBook, an Accessibility driver gave a fresh random project nickname to a live Codex Astra bot and selected Claude in its Model panel. The next message asked for the nickname without repeating it. In the Mac login session, Claude returned it exactly. The reply footer said Sonnet 5.5, but the header still showed Astra and said Claude would answer next.

On the fixed candidate, the same sequence ended with Sonnet 5.5 in both the header and the reply footer. The driver gave Claude a second random nickname, selected Codex and asked for the second nickname. The reply from GPT-6.2 Sol matched. The workspace journal recorded three distinct sessions, four completed replies and the same bot throughout. No reset or manual transfer was needed.

Launching a separate test from SSH also exercised a sign-in failure. The Claude CLI in that login context explicitly requested `/login` and a resend. Previously the chat still showed an active turn after 95 seconds. On the candidate it ended the turn, displayed the sign-in instruction and exposed **Retry sending this message**. Interactive sign-in screens that can resume keep their terminal action. This exercise did not change the user's credentials.

## Receiving an update with the sidebar hidden

Sparkle read the public appcast from a signed 0.8.15 build 49 and downloaded 0.8.16 build 50. In an SSH-only session on the build Mac, macOS refused to launch the installer. In the MacBook login session, Sparkle's command-line driver installed the public update into a private copy. The copy passed strict recursive code-signature verification and Gatekeeper reported “Notarized Developer ID”. Its bundled notes identified 0.8.16. The installed SwarmHub in Applications kept running.

For the window test, copies of the released and candidate apps used a private identifier, a temporary home, and a loopback mirror of the public appcast. With no chat selected, hiding the sidebar removed both “Review updates” and “Show sidebar” in the released interface. The candidate kept both controls visible. The driver clicked the compact update notice, opened Software Update, pressed **Update Now…** and observed Sparkle offer **Install Update**. After dismissing the offer, it opened **What’s New**, read the 0.8.16 entry about `/goal`, and restored the sidebar using the visible button. The installer test above used the unmodified public archives.

## Reopening a long group chat

A private MacBook workspace held two sample bots and a 620-message group. On opening the group, the normal native window showed its saved message 312. Jump to latest showed message 620. After quitting and launching again, the group reopened at 620. The driver paged back and quit. The third launch restored message 593, the position saved by the previous one. Every message ID was present and in order after the second quit. The fixture exercises local group history with a real app restart. [Repeat the window test](agent-qa.md#use-the-real-mac-window)

## Product comparison and remaining checks

- Collapsing the chat sidebar in OpenBot’s browser preview left “Expand sidebar” and “Open side panel” accessible. The SwarmHub Mac exercise above found the empty workspace case where the sidebar control disappeared. [OpenBot preview](https://openbot.run/app-preview)
- In OpenBot’s interactive preview, switching from Atlas to Forge changed the header’s model control from Claude Opus 5.5 to GPT-6 Luna and exposed its reasoning level. GameDev on SwarmHub 0.8.16 showed a static model name. On the candidate, a native Mac window with a synthetic session displayed its launch model and pending model together. Pressing that control opened the selected bot’s Model tab. A narrow-window rendering test checks that both names stay visible. [OpenBot preview](https://openbot.run/app-preview)
- OpenBot describes queued messages for a busy agent. Its public preview does not provide a matched live measurement for the Mac helper scenario above. [OpenBot product description](https://openbot.run/)
- Remote and disconnected servers still need end-to-end coverage. Read-only visits to Settings do not exercise credential changes or install software.
