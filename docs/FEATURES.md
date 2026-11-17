# SwarmHub features

What the macOS app does. Each item was checked against the code in `Sources/AgentApp`. The app has one backend: agents that Herdr Core runs, reached through the SwarmHub bridge (`swarmhub-herdr`). For what the bridge and its browser workspace do, see [HerdrWorkspace/README.md](../HerdrWorkspace/README.md). For what the Mac app does not do, see [Limits](ROADMAP-AND-LIMITS.md). For how the parts fit together, see [Architecture](architecture.md).

## The words the app uses

The app says **bot** everywhere. The agent program a bot runs on is its **AI** and goes by a short name: the one the server gives, else the program's own name without a last word such as "Code" ("Claude Code" reads "Claude"). A helper agent is a **helper**. The bridge is "the SwarmHub service" in the setup window and "the workspace" in Software Update. This page quotes the app's words in bold and uses the technical names where it explains how something works.

## Setup and servers

- The setup window opens by itself while there is no bot. Later it opens from the quick switcher (⌘K, **Set up…** or **Add a server…**), from **Set up** in the empty main window, and from **New Bot…** while no server is set up. Its steps are Where, Connect, Main bot and More bots, and on a server that can add project servers a last, optional one: Projects. More bots is left out when the server has no other AI to offer.
- A server is reached in one of three ways. The first step offers two of them; the third is folded under **Advanced**:
  - **This Mac.** The app looks for the bridge on `127.0.0.1:8787` and reads its access key from `~/.config/swarmhub-herdr/token`.
  - **A server.** The app runs the system `ssh` with your login to forward the bridge's port, reopens the forward when it drops, and reads the access key from the server's own file. It saves the path of an SSH key file, never the key.
  - **A server by address.** For a port you forwarded yourself. You type the address and paste the access key.
- **Connect** checks the connection and says what is wrong: nothing answers, the SSH login failed, the access key is missing or refused, the bridge answers without Herdr Core, or Core has no template to start an agent from. This Mac is checked without a press. With nothing running on this Mac, the window shows the command that starts the bridge.
- The app keeps a list of servers (**Settings → Servers**). Each bot runs on one of them. A server's parts are **Connection**, **Helpers**, **Skills** and **Projects**. **Add a server** adds one there, and **Check connection** tests one. Removing a server moves its bots to the first server left and changes nothing on the server itself.
- **New bots run on** (**Settings → Servers**) chooses the AI that new bots start on.
- Access keys are stored in the Keychain.
- "Get a ready-made server from us" is one line marked "Coming soon". It cannot be chosen and does nothing; a ready-made server is planned.

## Bots

- One bot is one agent on its server, named after the bot. Later messages go to the same running agent.
- **The bot starts when you open the chat.** An agent program takes from several seconds to a minute to start. When you open a bot's chat (and at launch, and when you come back to the app, for the chat on screen) the app starts that bot's agent if none is running, without a message, so your first message does not wait for it. Only the bot on screen is started, never the whole roster, and a bot never gets a second agent. The chat header says **Starting …** while the agent program starts and **Ready** with a green dot once a message is answered at once.
- A message you send while the bot is still starting waits for it and is delivered once. If the agent could not be started ahead of time, your first message starts it.
- **Keep _name_ ready** (Details, **Model**, **Advanced**; on by default) turns this off for one bot. A server that cannot start an agent program ahead of time is not asked again until the app restarts, and the switch says so.
- The server closes an agent that was started this way and never written to (after 30 minutes unless the server is set otherwise).
- A bot has a name, an avatar and instructions, and under **Advanced** in its settings an optional role. A bot that already has a description (from an import, or an older version) keeps it editable. The instructions are given to each agent the bot starts, once, with its first message.
- The **Model** tab of the Details panel chooses the **AI** and the **Model**, and nothing else in the app does. The choices are the ones the server offers. A bot with no model of its own starts on the first model the server lists. With more than one server, **Advanced** in the same tab chooses the bot's **Server**.
- **Start fresh** ends the running agent and, with **Keep _name_ ready** on, starts the next one at once. The chat stays; the bot's own memory of it does not.
- An agent that was started ahead of time and has not been written to is replaced when you change the bot's AI, model or projects, so the change applies at once. An agent that holds a conversation keeps running until **Start fresh**.
- **Add a bot for each AI** (**Settings → Servers → Connection**) adds one bot for each AI the server has that no bot uses yet.

## Chat

- The reply is shown while the bot writes it, and each tool call is a step under the reply.
- While a reply has no text yet, the line under it says what it is waiting for, as the server reports it: **Starting Codex… · the first reply takes longer**, **Delivered to Codex…**, **Codex is working…**, the running tool step (**Working… · Running a command · step 3**), **Codex is waiting for you in its terminal** (with a hand instead of the spinner), or **Finishing…**. The name is the AI's. The sidebar row says the same.
- The app follows a turn on the bridge's event stream and falls back to polling when the stream is unavailable or keeps breaking.
- **Stop** (**Chat → Stop Answer**) presses the agent's interrupt key. The agent stays open for the next message.
- A message sent while the bot answers is typed into the running agent. With **Read new messages mid-answer** off for a bot (Details, **Model**, **Advanced**), or when the message has attachments, the message waits and goes when the answer ends.
- **Retry** sends a message that was not sent once more, into the same row.
- Replies render Markdown. A reply can contain cards: a question with options, a draft with Send and Copy, link pills and inline images ([card syntax](reference.md#card-syntax)).
- A message can be answered with a reply to it or a tapback, and a finished reply can be copied.
- Quick switcher (⌘K), hidden chats, previous and next chat, and a window that lists the keyboard shortcuts (⌘/).
- Notifications for replies that arrive while the app is in the background (**Notify about new messages** in **Settings → General**; they need the app to run as an installed app), with a mute per bot.

## Main bot and creating bots

- Each server has one main bot (**Main bot** in the bot's settings, under **Advanced**). It wears a star in the sidebar, the chat header and its Details.
- The main bot creates bots. It asks the app in its reply. A bot it suggests shows above the composer with **Create** and **Not now**. A bot it decided on is added at once and shows there with **Keep** and **Remove**, so nothing it adds goes unseen.
- **Ask me before creating bots** makes every new bot wait for your Create.
- **New bot…** in the **+** menu of the main bot's composer writes the start of such a request into the composer.
- Any other bot that wants a new bot asks the main bot. The app passes the request into the main bot's chat, where it shows as a card with the asking bot's face, and the answer back.
- What a reply asks the app for is never drawn as code. It reads as one plain line under the reply, such as **Suggested a new bot: Legal**.
- A new bot is a record in the app. Nothing is created on the server until the bot gets its first message or its chat is opened.

## The first conversation and "About you"

- A main bot that the setup window has just created opens the conversation itself: the app sends it one note, shown in the chat as a single line (**SwarmHub asked Jarvis to say hello**), and the bot greets you, says what it can do, and asks up to five short questions, one per reply. Any question can be skipped. The note tells the bot to do no other work until asked.
- A main bot the setup window did not create (one from before, or one that was kept) offers this once above its composer (**Let Jarvis get to know you**, with **Start** and **Not now**). **Get to know me** in the **+** menu of the main bot's composer asks for it again.
- **About you** is a text of at most 800 characters that the app keeps (**Settings → General**) and gives to every bot's agent with its instructions. You can read and edit all of it.
- Only a main bot proposes additions, at most four per reply, each one sentence. Each shows above the composer with **Remember** and **Don’t save**; nothing joins the text until **Remember** is pressed. When the text is full, the app says so and the addition stays offered.

## Messages between bots

- A bot writes to another bot on its server by name. The app puts the message into that bot's chat as a card with the sender's face and only the sender's own words, and that bot's reply back into the sender's chat, so both chats show everything. The lines that tell the receiving agent how to answer are sent with it and not drawn. A bot that is answering another bot may write to one further bot first; its own answer goes back when that bot has answered.
- **Follow-ups.** A bot that has its answer may write to the same bot again, as Grok Bot's Bots hand work to each other and reply later. There is no one-round rule.
- **Limits, so that bots never go on by themselves for ever** ([How bots communicate](bot-communication.md), rule 6): within one piece of work the same two bots write to each other at most 8 times, the work passes through at most 4 bots, and one bot has at most 6 messages passed on in ten minutes. At a limit the message is not sent; the sender is told once, with the reason, to bring the matter to you, and the other bot's chat says so in a line. A bot that then tries again is not told again. Your next message to a bot starts a new piece of work.
- **Other bots can message it** (a bot's settings, under **Advanced**) turns incoming messages off for one bot. **Stop** in a bot's chat ends the exchanges it is part of, and the bots that wait for it read why.

## Helpers

- A bot is told how to start helpers unless **Can use helpers** is off in its settings (under **Advanced**).
- The bot's agent says how hard a task is (easy, medium or hard). The server's helper settings decide which AI and model each difficulty runs on; the agent cannot choose a model.
- Running helpers show under the bot in the sidebar, each with its model and its state. A helper opens as a read-only view of its task, steps, replies and terminal.
- **Settings → Servers → Helpers** reads and edits the server's helper settings: what easy, medium and hard tasks run on (or **Not allowed**), how many helpers one bot may run at once, how long a helper stays after its answer, and how long one may go without an answer.

## Projects on other servers

- A project server is a machine the Herdr server reaches over SSH with its own key. **Settings → Servers → Projects** shows one card per project server for the chosen server, with its state, the server's own warnings and its projects inside. A menu on each card has **Connect again** and **Remove …**. The setup window's last step offers the same.
- Adding one: the app shows the Herdr server's public key with a Copy button and where to paste it, then asks for the SSH address and a name. The first time the Herdr server sees a host, the app shows the host's fingerprints and how to check them; nothing is trusted until you press **Trust this server**. The result says whether Herdr's helper program was copied to the project server.
- A project is a name, a server, a folder on it and an optional note for the bots. The server checks that the folder exists before it saves one.
- A bot's settings (**Advanced**) and the **Overview** tab of its Details have a switch per project. A bot that may use a project can run commands and change files in that folder on that server. This is not a wall: every agent runs as the same account on the Herdr server, and that account can log in to every project server.
- A new agent starts with its bot's projects and is told about them by the server. A running agent gets a changed list at once and is told with the next message.
- The app adds no project server by itself, and a refusal is shown in the server's own sentence.

## Skills

- If skillshare is installed on the Herdr server, **Settings → Servers → Skills** and the **Skills** tab of a bot's Details list the server's skill library, by readable names ("Code review" for `code-review`), with a search field and a switch per skill.
- A switch changes the library and then runs a sync, so the AIs the library is shared with get the change. **Share with another AI…** (under **Advanced**) shares the library with one more.
- Skills belong to the server and its AIs, not to one bot. The app does not install or remove skills.

## Group chats

- A group is you and several bots in one thread. Each member answers through its own agent.
- `@Name` sends a message to the named members. A message that names nobody goes to every member.
- A round that a quit interrupted is marked in the chat and is not resumed by itself; the members it skipped offer **Retry**.

## Attachments and saved documents

- The composer takes images, text files (up to 200 KB) and documents: PDF, RTF, DOC and DOCX. Documents are read on the Mac and sent as text.
- An agent receives text only. An attached image is kept in the chat and is not sent to the agent.
- The **Media** tab of the Details panel lists the documents saved for a bot. From there you can read, export or attach one, share it with another bot, or remove a bot's access.

## Import

- **Grok Bot** (the **Grok Bot** card in **Settings → Servers**, and the **+** menu at the top of the sidebar; both show only when Grok Bot is on this Mac): reads Grok Bot's bots and history on this Mac. Each bot becomes a Herdr bot with a read-only history archive. Importing again adds what is missing without duplicates. Fetching all history asks macOS once for Grok Bot's sign-in.
- **Template** (**File → Import Template…**): a share link that returns export JSON, a JSON file, or an export folder written by `scripts/export-grokbot.py`. The import creates a Herdr bot from the template's name, title, description, instructions and avatar, and a report lists what was used and what was left out. Fields that look like credentials are rejected.

## Appearance and settings

- Settings is one window with four panes: **General**, **Servers**, **Software Update** and **About**.
- **General** holds your name (shown in group chats), **About you**, the theme (Light, Dark or System), the app icon (Light or Dark), the accent colour, avatar motion and notifications.
- The look comes from the app icon: warm surfaces (cream in light, olive charcoal in dark) and a clay accent by default. Sage, Graphite and five other accents can be chosen.
- Each chat carries its bot's colour, taken from its avatar: a soft wash behind its name in the header, its face and name above the first reply of each run, and the cards above the composer.
- Avatars come from the vendored BotAvatarsKit.

## Sample bots

- **Look around with sample bots**, in the main window while there is no bot, opens the app with sample bots that answer locally. Nothing is sent to a server. The samples are removed once a real bot exists.

## Updates

- **Settings → Software Update** shows in one place whether everything is up to date, and has one button (**Update Now** or **Update All**) when something is behind: the servers first, then the app. **Check Now** asks again. While an update waits, a line at the bottom of the sidebar opens the page.
- **The app** updates through Sparkle. Two switches: **Check for updates automatically** (once a day, in the background, without a window over your work) and **Install updates automatically** (downloads in the background and installs when you quit). **Update Now…** opens Sparkle's window with the release notes. **Check for Updates…** in the SwarmHub menu does the same for the app alone. An app that is run as a bare executable does not update itself.
- **Each server** has a card with its workspace version (the bridge's) and its Herdr Core version. **Update** has the server install the newest signed workspace release itself; the workspace restarts and the agents keep running. A server that cannot reach the releases is handed the release by the app. The ••• menu has **Check Again**, **Update Herdr Core** and, after an update, **Go Back from Workspace …**.
- A server whose workspace is from before it could update itself is reported as needing an update by hand, once.
- How it works, what is trusted and the release steps: [Updates](updates.md).

## Stores from older versions

- Older versions also ran bots on two other backends, which were removed. A store that holds such bots is first copied as it was to `store.json.before-herdr-only-<time>` beside it. The app then loads and saves the store without those bots and says once how many were left out and where the copy is.
