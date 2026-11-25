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

## Sending a correction while the bot starts

The MacBook driver paused a private workspace’s SSH forward, pressed Send on a request to run a command and return a unique word, then submitted a different word through the same chat composer. Both presses cleared the input before the forward resumed.

On the baseline, the second button read **Queue as the next message**. The workspace recorded two tasks and replied with each word in turn. On the candidate, **Send follow-up when the bot starts** accepted the correction in a chat with an imported history fixture. The remote Codex command ran, the workspace recorded one task, and its only reply used the corrected word. The chat showed **Delivered**. A repeat on the final build asked the bot to include the project name from the imported conversation. Its only reply combined the correction’s unique word with the archived name, and the native window displayed that reply and its receipt.

## Losing the server connection during a command

A native MacBook chat sent a command to an isolated Codex workspace on a second Mac over SSH. The command created a marker, slept for 12 seconds and returned a unique reply. After the marker appeared, the driver closed the data tunnel for 16 seconds. An independent connection could still read the workspace journal.

Before the fix, the chat showed **Incomplete** by the six-second check. Even 75 seconds after the connection returned, the saved reply was missing from the chat. The server had recorded one task and one reply.

With the fix, the chat showed **Reconnecting to the workspace…** while the command ran. Its saved reply appeared 0.8 seconds after the tunnel reopened. A second message in the same chat received its answer in 5.1 seconds. The server recorded exactly two tasks and two matching replies. This exercise used a manually restored SSH forward. The client retries reads of an accepted turn for up to two minutes with increasing delays. A permanent refusal such as an invalid access token ends the wait immediately.

A second exercise used the SSH connection managed by SwarmHub. The driver terminated the app’s own SSH forward after the command started. SwarmHub opened a replacement forward automatically. The reply to the 12-second command was visible 14.9 seconds after the disconnect. A follow-up received its answer in 9.8 seconds. Both tasks appeared exactly once in the remote journal.

## Opening a bot’s media again while its workspace is offline

A private copy of the Mac app opened a saved bot reply containing a PNG and an MP4. A loopback server served the same authenticated download routes used for published results. On the baseline, the chat fetched both files again when the user switched away and back. With the server returning HTTP 503, both previews offered **Retry preview**. Quitting and opening the chat again produced two more failed requests.

On the fixed build, the native driver opened the image preview sheet and pressed the inline video player’s play control online, after reopening the chat offline, and after relaunching the app offline. The video control reported playing in each run. The server received one download request per file across the entire exercise. Media that has never been downloaded, or has been evicted from the bounded Mac cache, requires the workspace to be reachable. [Repeat the Mac media test](agent-qa.md#use-the-real-mac-window)

## Upgrading from the public 0.8.16 executable

The public archive for build 50 contains Apple silicon and Intel executables. Running the existing release packaging script against the merged fixes on an Apple silicon Mac produced an arm64-only archive. The corrected release path produced a universal executable. Both slices reported macOS 14.0 as their minimum system. The app launch check passed natively and under Rosetta. Physical Intel hardware was not used.

A private MacBook installation started with the executable from the published 0.8.16 ZIP. The archive digest matched the GitHub asset. The test copies used a private bundle identifier, a loopback feed, and disposable signing keys. Sparkle fetched the candidate with the wrong signature and kept build 50. When the trusted key signed the same archive, Sparkle installed it. The installed executable matched the candidate and passed its code signature and launch checks. On the universal release build, the native chat tests also opened an image and played a video offline and restored the 620-message group’s saved position after relaunch. [Repeat the update test](updates.md#rehearsing-without-credentials)

## Adding Antigravity with a bot’s model picker open

The Mac’s installed workspace service reported Antigravity CLI registered. In a private app copy, the driver opened the model picker with Claude available, opened AI settings, and exposed Antigravity to the service in a temporary search path. The released workspace service handled registration. A loopback catalog controlled when the workspace could confirm the new template.

On the baseline, **Add Antigravity CLI** wrote the template while the endpoint was unavailable. Settings showed **Added**. After the endpoint recovered, **Scan again** still left the open bot picker offering only Claude. With the fix, the offline receipt reads **Registered on this Mac**. A successful rescan changes it to **Added** and updates the open picker. [Repeat the native inventory test](agent-qa.md#use-the-real-mac-window)

## Updating the app and workspace behind a running job

On the MacBook, a private copy of the universal app at `c739cd12` connected to workspace 0.2.13 built from the public 0.8.16 tag. The driver started a five-minute job in a private Herdr Core session, opened **Settings → Software Update** and clicked **Update**. The workspace installed 0.2.14 from a loopback feed signed with a test key. The workspace process kept its PID, the job stayed in Core, and the installed program and rollback copy matched the two original binaries byte for byte.

In a separate Sparkle rehearsal, the executable from the public 0.8.16 build 50 ZIP downloaded the candidate. The incorrect signing key left build 50 installed. With the trusted test key the candidate installed on quit and passed code-signature verification. Both exercises used private app copies and disposable signing keys.

The public feed offered app 0.8.16 build 50 and workspace 0.2.13. The verifier checked the app signature with the installed app’s trusted key and downloaded all three workspace programs to check them against their signed manifest. Giving it the staged 0.2.14 manifest correctly failed. Release preparation previously treated a network error as an absent workspace feed, which could drop these programs from an app-only release. Preparation now stops on an unreadable feed and on a missing signature for an existing manifest.

## Finding a saved message from the sidebar

In a private native Mac chat, the driver opened a group and confirmed that “Review the competitor brief” was visible in its transcript. In sidebar **Search**, entering the name of the fixture bot returned that bot. Entering “competitor brief” returned an empty list. The sheet offered only **Done**. The switcher currently searches bot names, group names and actions. A user trying to recover an older message cannot find it this way.

In OpenBot’s interactive preview, the driver opened **Search OpenBot** and entered the same phrase. The list included a message from Atlas, highlighted the matching words and showed the surrounding text and time. Starting from Forge, selecting this message under **Messages** opened the Atlas conversation with the matching reply visible. [OpenBot preview](https://openbot.run/app-preview)

On the patched Mac app, **Search** returns message excerpts with the chat, author and time. In an 800-message private workspace the driver searched from a bot chat, opened group message 452, switched directly to bot message 37 and then found message 88 in that same chat. Each target was outside the current page. The check measured each row against the visible scroll area. In one run those three rows appeared within 0.52–0.68 seconds of selection. A fourth query returned 21 hits. Ten Down Arrow presses and Return opened the eleventh result. This run covered SwarmHub bot and group messages. [Run the window check](agent-qa.md#use-the-real-mac-window)

## Finding imported Grok messages

A search from a bot with 400 live rows found its saved SwarmHub messages but timed out looking for a phrase in an imported group archive. The candidate returned the archived message with its source and conversation, opened it in the group transcript and showed its surrounding entries. The driver paged back and forward, then used Return to open an imported reply in another bot. The two archives used overlapping entry IDs and a selected entry with only a sequence number. A hidden prompt containing the same phrase stayed out of the results.

Switching away initially lost the imported reading position. The corrected candidate restored the group’s selected entry after switching back and the bot’s entry after quitting and relaunching. In a separate MacBook run with 33,000 imported entries (31,879,382 bytes), the group and bot archive results appeared 0.38 and 0.44 seconds after entry of the full phrase. After the driver removed one test archive and relaunched, the affected bot opened at its newest live message. Times are for this synthetic local workspace. [Run the window check](agent-qa.md#use-the-real-mac-window)

## Quitting during a remote reply and reopening offline

In a private MacBook chat, the driver sent a command to a real Codex bot on a second Mac. Once the command started, it disconnected the SSH forward and quit SwarmHub. The remote workspace recorded the completed answer. On the baseline, the chat reopened with the partial text and an **Incomplete** footer. The answer was still missing 32 seconds after reconnection.

With the fix, the chat reopened offline and displayed **Checking the workspace for your reply…**. After the connection returned, the saved answer appeared in the original bubble in 3.93 seconds. The driver checked its ID, text and finished state on disk, then sent another message from the same chat. The remote journal contained exactly two tasks and their two answers. This exercise covered a newly accepted direct message. Older partial replies without a delivery receipt still lack enough information to identify the task on its workspace.

## Steering a remote bot before quitting

Two private MacBook chats exercised the **Send into the current answer** button while Codex was running a command on a second Mac. In the first run, the app quit immediately after the workspace accepted the follow-up. On the baseline, the saved answer appeared above the instruction that produced it. In the second run, the follow-up asked Codex to start a second command. The driver waited for that command to start before quitting. The workspace had the answer, but the baseline still showed an empty incomplete reply 32 seconds after reconnecting.

On the patched app, the answer appeared below the accepted instruction in both runs, about four seconds after reconnecting. The earlier progress stayed above the follow-up, and sending another message produced one more answer. Each workspace journal contained two ordinary tasks and two replies across the exercise. Live guidance went into the original task. [Repeat the offline window check](agent-qa.md#use-the-real-mac-window)

## Seeing background answers from another chat

The Mac window driver opened a third chat while two bot replies were pending on a loopback workspace. When the workspace returned, both answers appeared on disk, but both unread counts were zero. The open conversation gave the user no indication that the other bots had finished.

With the fix, the third chat kept its draft and keyboard focus. Each completed bot gained one unread mark, exposed in the sidebar for both a pinned tile and a regular row. Opening the coding helper beneath the regular row kept its parent unread. Returning to the parent cleared that mark. The other bot stayed unread through an offline relaunch and cleared when opened.

In a separate run with a real Codex session on a second Mac, the driver steered an active command, disconnected the workspace, quit the MacBook app and reopened another bot’s chat offline. The original bot showed an unread badge 4.61 seconds after reconnection. Opening it showed the final answer below the accepted guidance and cleared the badge. The next message received a reply. The workspace recorded two ordinary tasks for the full exercise. [Repeat the sidebar and recovery check](agent-qa.md#use-the-real-mac-window)

## Replies arriving while the selected chat is out of view

A MacBook test sent messages in a private direct chat and group. Minimizing the window, hiding the app or opening Settings before the reply finished left both conversations with zero unread replies. The saved transcript contained each answer.

On the patched app, all ten combinations of direct or group chat and minimized window, hidden app, foreground Finder, Settings or Search passed. Each reply stayed unread until the chat window regained focus. Returning to that window cleared the mark without requiring another click on the conversation. [Repeat the window check](agent-qa.md#use-the-real-mac-window)

In a separate real Codex run on a second Mac, the driver steered a running command, disconnected the workspace, quit the MacBook app and reopened it offline. It kept the same chat selected and minimized its window. The finished answer was saved and marked unread 4.30 seconds after the forward was restored. Bringing the window back cleared the count and showed the answer underneath the guidance. The next message also received its answer. The server journal recorded two ordinary requests and two final replies.

## Finding a chat that needs you

The native sidebar showed individual unread badges. Opening Search in a private two-bot workspace also offered no cross-chat activity list. In OpenBot’s preview, opening **Threads** exposed example tasks grouped by **Needs you**, **Working** and **Waiting**. [OpenBot preview](https://openbot.run/app-preview)

In SwarmHub, **Activity** in the sidebar or Navigate menu now opens a list of visible chats that need attention, have work running or queued, or have unread messages. A MacBook test opened an unread group, came back to its draft in another chat, sent the draft, and kept Activity open until the answer arrived. An early build kept displaying “Typing…” after the reply had finished. The regression checks that the row changes to the actual answer, opens that answer, then disappears. It also opens an interrupted reply and exercises the Activity shortcut with the sidebar hidden. [Run the native activity check](agent-qa.md#use-the-real-mac-window)

With a real Codex session on another Mac, the first build reported a running shell command while the workspace had an unanswered approval and the command had never started. The candidate reads the workspace’s pending approvals and checks their session identity. While the user was in another chat, Activity showed **Review Bash**. Opening it led to the approval card. After **Allow once**, the command ran, the answer became unread, and selecting it opened the reply. The journal recorded one ordinary request and one final reply. In a separate group run, the row named both the group and the member requesting approval. Clicking **Allow once** in the group released its own command. Its final reply also opened from Activity. The Swift session-matching regression rejects an approval from an older launch at the same address and a cached inbox from a different server binding.

The debug build also logged a SwiftUI AttributeGraph cycle during sheet transitions. The final native runs completed navigation and updated the visible status through those transitions. The cause of the diagnostic remains open.

## Stopping while the workspace is disconnected

The native test started a real Codex shell command on a second Mac, hid the sidebar, disconnected the private workspace and pressed **Stop response**. The remote journal subsequently contained the final answer. On the original build the Mac saved a stop failure beside a reply marked stopped. Nine seconds after reconnecting, that row still had no final answer. A separate regression on the command dispatcher showed that a transient connection banner disabled Activity, Search and next-chat navigation.

With the fix, the transcript shows **Stop unconfirmed. The bot may still be running.** Activity also identifies the affected chat. With the connection banner visible and the sidebar hidden, the driver opened Activity and Search by keyboard, then switched to a local chat. After the remote command finished, reconnecting recovered its answer into the original conversation and raised its unread count. In a separate group run, the driver quit and relaunched the app offline. The group answer appeared about six seconds after connection was restored. Each remote journal contained one task and one answer. The app only reads the journal to recover that answer. Recovery needs the saved delivery receipt and a matching journal entry. Older conversations without a receipt can show that Stop failed, but cannot identify the final answer automatically.

The workspace can also acknowledge an interrupt while reporting that its agent is still working. HTTP fixture tests cover stopped, exited, still working, unknown and older responses without an outcome in both direct and group sessions. The Mac retains the delivery receipt when the response leaves the result unconfirmed.

The native regression includes a saved group request that was waiting for stop confirmation when the app closed. It checks the warning while offline, the unread badge after reconnecting, and the final text and identity of the group reply after relaunch. [Repeat the recovery check](agent-qa.md#use-the-real-mac-window)

## Comparing the Mac workspace with swarmhub.org

In Chromium, the driver stepped through the release notes, failed CI check, daily brief and new bot proposal examples on the live home page. It opened Patch’s Overview, Team and Skills and switched the preview between dark and light. The walkthroughs use sample data. [Interactive workspace](https://swarmhub.org/#workspace) · [Advertised features](https://swarmhub.org/features/)

The Mac app now uses the preview’s chat, sidebar, panel and card colors. The header puts the bot’s role beneath its name and gives the model control a button outline. The separate lines for a running model and a pending change still fit. The two captures show a native 980 × 620 pt workspace with sample chats. [Dark appearance](screenshots/dark/workspace-compact.png) · [Light appearance](screenshots/light/workspace-compact.png)

| Website workflow | How it was checked |
| --- | --- |
| Hand off work and review the result | In a private Mac window, opened Team, read a completed exchange and a scheduled CI watch from a loopback workspace. Switching to another bot cleared both. An earlier version only requested open exchanges. [Bot-to-bot trials](bot-communication-results.md) |
| Review CI failures and scheduled work | Workspace tests cover polling the watched PR head, waking once on failure, cancellation, and scheduling. The Team window check uses a recorded-shape watch. No live GitHub Actions failure was triggered for this test. |
| Create a specialist and inspect a helper | A live Codex bot on a second Mac created ReleaseReader and presented a separate Payments proposal in the Mac app. The saved workspace contained ReleaseReader and the Payments proposal still offered Create. The Swift suite covered helper policies and separate coding model choices. |
| Steer, approve and continue a chat | Real Codex direct and group trials above cover steering, approvals, interruption and recovery. The Mac window tests also covered 620 saved group messages, inline image and video playback, and search in live and imported history. |
| Use local or SSH projects, shared skills, MCP and hooks | The workspace suite covered project scoping. The skillshare integration test used a scratch library and local Git repositories for previews, installation, updates, synchronization and removal. The bridge and Chrome integration test used an isolated Core and exercised desktop and mobile viewport widths. |
| Choose a provider, use goals, import history and update | The Swift suite covered per-bot model changes, goals, Gemini beta registration and Grok import. In one MacBook chat, Codex saved a random codeword, then Claude returned it after a provider change. The remote journal confirmed both launches and two replies. Discovery on the MacBook reported Claude, Codex and Antigravity CLI. Signed-in Gemini CLI and OpenRouter chats and a physical Intel Mac were outside this pass. See the signed update rehearsal above. |

The features page also advertises several workflows beyond the four home-page examples. These checks record the limits of this pass.

| Additional website promise | Status in this checkout |
| --- | --- |
| Unified attention queue and keyboard decisions | Activity leads to pending direct and group approval cards. Keyboard decisions also work inside Activity. With another chat open, the two-Mac driver inspected the shell arguments and pressed ⌘Return or ⌘Delete on separate runs. The workspace received each decision. |
| Scoped rules and cross-model command review | The bridge supports expiring exact-read approvals. The review and execution of a risky terminal command by a separately selected reviewer was not verified. |
| Paste screenshots into four providers | Codex, Claude Code and Antigravity each read a random code from an image pasted into the Mac chat. Gemini CLI and OpenCode V2 each sent the original PNG bytes to a local test endpoint. Live recognition through Google’s standalone Gemini CLI and OpenRouter remains unverified. |
| Routines, webhooks and Pages | The Mac has a routines editor and artifact library. Workspace and Swift suites exercise these paths. This pass did not use an external webhook service. |
| Context and spend limits, interactive helpers | The Mac exposes goals and read-only helper sessions. Live cost accounting, per-goal spend ceilings and promotion of a running helper were not demonstrated. |
| SSH bootstrap, iPhone approvals and Team Packs | The two-Mac runs used an existing SSH connection. In Safari on a simulated iPhone 17e, the driver unlocked the live workspace, opened Review in chat, inspected a real Codex shell request and tapped Allow once. The native Mac driver exported two bots from a group, reviewed the pack and created a new group from the JSON. Each imported bot had the expected instructions, a new identity and an empty chat. The standalone native iPhone app remains unverified. |

On the first Mac build, closing Details, immediately reopening it and switching bots could leave the inspector closed. A resizable Mac split view now keeps the panel open through the sequence. The window driver repeated it in both appearances and checked the Media and Close controls at the minimum window size.

On iPhone Safari, the original chat header put the back button at 15 pt from the top, under the status bar. The updated workspace keeps that control below the inset and displays **Review** in the chat header whenever there is a pending item. The iPhone run used Safari on iOS 27.2 Simulator. Chrome also opened the review queue inside a mobile-width chat, reviewed two webhook events and checked that the button disappeared after the last decision.

OpenCode 1.18.5 returned HTTP 409 during model discovery because its CLI does not support the V2 adapter. On the Mac, the bot’s Model tab silently displayed an empty catalog. The service also missed systems with only the V2 executable named `opencode2`. The patched native Mac app found and registered that executable without starting it. The driver selected OpenCode, saw the fixture’s model-list error, pressed **Reload models** and saw the search field appear for the recovered 13-model catalog. Selecting Antigravity afterwards affected only that bot.

With the CLI paused during model enumeration, a second request for the same catalog returned HTTP 409 on the original workspace. After the fix, both requests received the four expected models from one CLI invocation.

In a separate Linux run, OpenCode 2.4.1 listed four models from a local OpenAI-compatible provider without requesting inference. In Chrome, the test launched an OpenCode bot, approved its command once, checked that the reply was saved and verified that a second permission request returned to the terminal. Live OpenRouter account access remains unverified.

The same native test pass found a keyboard search issue. In a list of 21 results, scrolling the keyboard highlight under a stationary pointer could change the result selected by Return. A failing run opened message 133 after ten Down Arrow presses from message 148. The fixed run opened message 138, then navigated to imported group and bot messages. [Repeat the Mac checks](agent-qa.md#use-the-real-mac-window)

## Pasting a screenshot with a text caption

In a disposable MacBook window, the driver pressed ⌘V with an image and its text description on the same clipboard item. The original composer inserted “Clipboard label” and discarded the screenshot. With the fix, a preview appeared and the text field stayed empty. The run used a private pasteboard.

For each live trial, the driver pasted a different PNG, typed the same question and pressed Send. Each six-character code appeared only in the pixels. Codex, Claude Code and Antigravity all returned their own codes. The saved attachment and the file staged in each remote bot’s workspace matched the original by SHA-256.

In a fourth Mac window, the driver selected the standalone Gemini CLI, pasted the image and sent it to a Linux workspace. Gemini CLI 0.71.1 sent the matching PNG as inline image data to a local Google-compatible test endpoint, and the endpoint’s reply appeared in chat. A separate live Google attempt stopped at its OAuth sign-in prompt. On Linux, an OpenCode 2.4.1 integration test uploaded a PNG in a first message, observed an image part with the exact bytes at the local model endpoint, and found the endpoint’s reply in the workspace journal. Neither endpoint test measures a live model’s image recognition.

## Product comparison and remaining checks


- Collapsing the chat sidebar in OpenBot’s browser preview left “Expand sidebar” and “Open side panel” accessible. The SwarmHub Mac exercise above found the empty workspace case where the sidebar control disappeared. [OpenBot preview](https://openbot.run/app-preview)
- In OpenBot’s interactive preview, switching from Atlas to Forge changed the header’s model control from Claude Opus 5.5 to GPT-6 Luna and exposed its reasoning level. GameDev on SwarmHub 0.8.16 showed a static model name. On the candidate, a native Mac window with a synthetic session displayed its launch model and pending model together. Pressing that control opened the selected bot’s Model tab. A narrow-window rendering test checks that both names stay visible. [OpenBot preview](https://openbot.run/app-preview)
- From Atlas’s model picker, pressing **Add provider** in the OpenBot preview opened provider settings with a search field and a Gemini entry. SwarmHub now puts **Manage AIs on this Mac…** beside the bot’s own AI choices. [OpenBot preview](https://openbot.run/app-preview)
- OpenBot describes queued messages for a busy agent. Its public preview does not provide a matched live measurement for the Mac helper scenario above. [OpenBot product description](https://openbot.run/)
- The remote exercises cover connection loss after delivery with SwarmHub open and with an offline relaunch. Changing workspace credentials mid-turn remains untested.
