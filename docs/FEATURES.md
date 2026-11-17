# SwarmHub features

What the macOS app does. The app has one backend: agents that Herdr Core runs, reached through the SwarmHub bridge (`swarmhub-herdr`). For what the bridge and its browser workspace do, see [HerdrWorkspace/README.md](../HerdrWorkspace/README.md). For what the Mac app does not do, see [Limits](ROADMAP-AND-LIMITS.md).

## Setup and servers

- The setup window opens by itself while there is no bot, and from **Settings → Set up…**. Its steps are Where, Connect, Main bot and More bots, and on a server that can add project servers a last, optional one: Projects.
- A server is reached in one of three ways:
  - **This Mac.** The app looks for the bridge on `127.0.0.1:8787` and reads its access key from `~/.config/swarmhub-herdr/token`.
  - **A server I reach over SSH.** The app runs the system `ssh` to forward the bridge's port, reopens the forward when it drops, and reads the access key from the server's own file. It saves the path of an SSH key file, never the key.
  - **A server by address and access key.** For a port you forwarded yourself.
- **Test** checks the connection and says which of four things is wrong: nothing answers, the access key is refused, the bridge answers without Herdr Core, or Core has no template to start an agent from.
- The app keeps a list of servers (**Settings → Advanced → Servers and keys**). Each bot runs on one of them. Removing a server moves its bots to the first server left and changes nothing on the server itself.
- Access keys are stored in the Keychain.
- "Get a ready-made server from us" is a placeholder. It does nothing.

## Bots

- One bot is one agent on its server, named after the bot. Later messages go to the same running agent.
- **The agent starts when you open the chat.** An agent program takes from several seconds to a minute to start. When you open a bot's chat (and at launch, and when you come back to the app, for the chat on screen) the app starts that bot's agent if none is running, without a message, so your first message does not wait for it. Only the bot on screen is started, never the whole roster, and a bot never gets a second agent. The chat header says **Starting …** while the agent program starts and **Ready** with a green dot once a message is answered at once.
- A message you send while the agent is still starting waits for it and is delivered once. If the agent could not be started ahead of time, your first message starts it, as before.
- **Keep its agent ready** (the **Model** tab, on by default) turns this off for one bot. A server that cannot start an agent program ahead of time is not asked again until the app restarts, and the switch says so.
- The server closes an agent that was started this way and never written to (after 30 minutes unless the server is set otherwise).
- A bot has a name, an avatar, instructions, a title and a description. The instructions are given to each agent the bot starts, once, with its first message.
- **Herdr agent** (the bot's settings under Advanced, and the **Model** tab of the Details panel) chooses the server, the agent program and the model. The choices are the ones the server offers. A bot with no model of its own starts on the first model the server lists.
- **Start a fresh agent** ends the running agent and, with **Keep its agent ready** on, starts the next one at once. The chat stays; the agent's own memory of it does not.
- An agent that was started ahead of time and has not been written to is replaced when you change the bot's agent program, model or projects, so the change applies at once. An agent that holds a conversation keeps running until **Start a fresh agent**.
- **Add starter bots** in Servers and keys adds one bot for each agent program the server has.

## Chat

- The reply is shown while the agent writes it, and each tool call is a step under the reply.
- While a reply has no text yet, the line under it says what it is waiting for, as the server reports it: **Starting Codex… · the first reply takes longer**, **Delivered to Codex…**, **Codex is working…**, the running tool step (**Working… · Running a command · step 3**), **Codex is waiting for you in its terminal** (with a hand instead of the spinner), or **Finishing…**. The name is the agent program's. The sidebar row says the same.
- The app follows a turn on the bridge's event stream and falls back to polling when the stream is unavailable or keeps breaking.
- **Stop** presses the agent's interrupt key. The agent stays open for the next message.
- **Steer:** a message sent while the agent answers is typed into the running agent. With steer off for a bot, or when the message has attachments, the message waits and goes when the answer ends.
- **Retry** sends a message that was not sent once more, into the same row.
- Replies render Markdown. A reply can contain cards: a question with options, a draft with Send and Copy, link pills and inline images ([card syntax](reference.md#card-syntax)).
- Quick switcher (⌘K), hidden chats, previous and next chat, and a window that lists the keyboard shortcuts (⌘/).
- Notifications for replies that arrive while the app is in the background, with a mute per bot.

## Main bot and creating bots

- Each server has one main bot (the bot's settings, Advanced → Main bot). It wears a star in the sidebar.
- The main bot creates bots. It asks the app in its reply; the app adds a bot it decided on at once, and shows one it asks about above the composer with **Create** and **Dismiss**.
- **Ask me before creating bots** makes every new bot wait for your Create.
- Any other bot that wants a new bot asks the main bot. The app passes the request into the main bot's chat and the answer back.
- A new bot is a record in the app. Nothing is created on the server until the bot gets its first message.

## Messages between bots

- A bot writes to another bot on its server by name. The app puts the message into that bot's chat, marked as passed on, and that bot's reply back into the sender's chat, so both chats show everything. A bot that is answering another bot may write to one further bot first; its own answer goes back when that bot has answered.
- **Follow-ups.** A bot that has its answer may write to the same bot again, as Grok Bot's Bots hand work to each other and reply later. There is no one-round rule.
- **Limits, so that bots never go on by themselves for ever** ([How bots communicate](bot-communication.md), rule 6): within one piece of work the same two bots write to each other at most 8 times, the work passes through at most 4 bots, and one bot has at most 6 messages passed on in ten minutes. At a limit the message is not sent; the sender is told once, with the reason, to bring the matter to you, and the other bot's chat says so in a line. A bot that then tries again is not told again. Your next message to a bot starts a new piece of work.
- **Other bots can message it** (a bot's settings) turns incoming messages off for one bot. **Stop** in a bot's chat ends the exchanges it is part of, and the bots that wait for it read why.

## Helper agents

- A bot is told how to start helpers unless **Can start helper agents** is off in its settings.
- The agent says how hard a task is (easy, medium or hard). The server's helper settings decide which agent program and model each difficulty runs on; the agent cannot choose a model.
- Running helpers show under the bot in the sidebar. A helper opens as a read-only view of its task, tool calls, replies and terminal.
- **Settings → Advanced → Servers and keys** reads and edits the server's helper settings.

## Projects on other servers

- A project server is a machine the Herdr server reaches over SSH with its own key. **Settings → Advanced → Servers and keys → Projects** lists them for the chosen Herdr server, with each one's state and the server's own warnings, and has **Connect again** and **Remove…**. The setup window's last step offers the same.
- Adding one: the app shows the Herdr server's public key with a Copy button and where to paste it, then asks for the SSH address and a name. The first time the Herdr server sees a host, the app shows the host's fingerprints and how to check them; nothing is trusted until you press **Trust this server**. The result says whether Herdr's helper program was copied to the project server.
- A project is a name, a server, a folder on it and an optional note for the bots. The server checks that the folder exists before it saves one.
- A bot's settings (**Advanced**) and its **Details** have a switch per project. A bot that may use a project can run commands and change files in that folder on that server. This is not a wall: every agent runs as the same account on the Herdr server, and that account can log in to every project server.
- A new agent starts with its bot's projects and is told about them by the server. A running agent gets a changed list at once and is told with the next message.
- The app adds no project server by itself, and a refusal is shown in the server's own sentence.

## Group chats

- A group is you and several bots in one thread. Each member answers through its own agent.
- `@Name` sends a message to the named members. A message that names nobody goes to every member.
- A round that a quit interrupted is marked in the chat and is not resumed.

## Attachments and saved documents

- The composer takes images, text files (up to 200 KB) and documents: PDF, RTF, DOC and DOCX. Documents are read on the Mac and sent as text.
- An agent receives text only. An attached image is kept in the chat and is not sent to the agent.
- The **Media** tab of the Details panel lists the documents saved for a bot. From there you can read, export or attach one, share it with another bot, or remove a bot's access.

## Voice

- Dictation: record with the microphone button in a chat, stop, and the recording is transcribed by deAPI with your own API key (**Settings → Advanced → Voice**). The text is added to the draft and is never sent by itself. A recording is at most 5 minutes and is removed from the Mac after transcription or cancellation.
- Read aloud: the speaker button under a finished reply speaks it with the Mac's built-in speech; press it again to stop. Nothing is sent anywhere.

## Import

- **Grok Bot** (**Settings → Advanced → Servers and keys → Grok Bot**): reads Grok Bot's bots and history on this Mac. Each bot becomes a Herdr bot with a read-only history archive. Importing again adds what is missing without duplicates. Fetching all history asks macOS once for Grok Bot's sign-in.
- **Template** (File → Import Template…): a JSON file or an export folder written by `scripts/export-grokbot.py`. The import creates a Herdr bot from the template's name, title, description, instructions and avatar, and a report lists what was used and what was left out. Fields that look like credentials are rejected.

## Appearance and settings

- Theme (Dark, Light or System), accent colour and Dock icon.
- Avatars from the vendored BotAvatarsKit, with a setting for avatar motion.
- Your name, shown in group chats.
- Settings has a simple page and four Advanced panes: Servers and keys, Appearance and alerts, Voice, About.

## Sample agents

- **Look around with sample agents** in the setup window opens the app with sample bots that answer locally. Nothing is sent to a server.

## Updates

- Installed builds update through Sparkle: checked once a day, installed now or when you quit. Automatic download and install is a setting under Advanced → About. See [Automatic updates](updates.md).

## Stores from older versions

- Older versions also ran bots on two other backends, which were removed. A store that holds such bots is first copied as it was to `store.json.before-herdr-only-<time>` beside it. The app then loads and saves the store without those bots and says once how many were left out and where the copy is.
