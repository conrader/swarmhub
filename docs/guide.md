# SwarmHub guide

How to set up the Mac app and use it. The app chats with agents that Herdr Core runs. It reaches them through the SwarmHub bridge, a service that runs beside Herdr Core on the same machine.

The app uses plain words for these parts, and so does this guide where it quotes the app. A bot's agent program is its **AI** and goes by a short name ("Claude", "Codex"). The bridge is "the SwarmHub service" in the setup window and "the workspace" in Software Update.

<a id="how-it-works"></a>

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/overview-dark.svg">
  <img src="diagrams/overview-light.svg" alt="The Mac app talks to the SwarmHub bridge on the Herdr server; the bridge talks to Herdr Core, which runs the agent programs." width="1080">
</picture>

A bot in the app is one agent on a Herdr server: an agent program such as Claude Code or Codex, running in a terminal there. Your message goes from the app to the bridge, Herdr Core types it into the agent, and the reply comes back as it is written. [Architecture](architecture.md) has the details.

## Get started

### 1. Run Herdr Core and the bridge

Bots work on the computer that runs Herdr Core: this Mac or a server. The Mac app does not install or start Herdr Core or the bridge. Follow [Run locally](../HerdrWorkspace/README.md#run-locally) on that computer. `HerdrWorkspace/dev/start-local.sh` starts an installed bridge and keeps its access key in `~/.config/swarmhub-herdr/token`, which is where the app looks for it.

Herdr Core needs at least one agent template, for example for Claude Code or Codex. Open each agent program once in the folder the agents start in, because a program that asks whether to trust a new folder gets no task.

### 2. Start the app

Build and run from a checkout on a Mac with Xcode:

```sh
./scripts/run.sh
```

The packaged build on the [releases page](https://github.com/conrader/swarmhub/releases) (0.6.8) is the earlier version of the app, from before it moved to Herdr Core, and does not match this guide. Use it only once a newer release is published.

### 3. Connect

The setup window opens while there is no bot. Later, open it from the quick switcher (⌘K): **Set up…**, or **Add a server…** once every server has its main bot. The empty main window has a **Set up** button too.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/dark/setup-where.png">
  <img src="screenshots/light/setup-where.png" alt="The setup window: where should your bots run? This Mac, A server, a ready-made server marked Coming soon, and Advanced." width="480">
</picture>

The screens in this guide are rendered by the app with sample content.

1. **Where.** Choose **This Mac** or **A server**, which the app reaches with your SSH login. **Advanced** holds a third way, **A server by address**, for a server whose port you already forwarded to this Mac. "Get a ready-made server from us" is marked "Coming soon" and cannot be chosen.
2. **Connect.** This Mac needs nothing typed and is checked as soon as you press **Continue**. For a server, give the server's name and, if needed, a login name and the path of an SSH key file, then press **Connect**; a key with a passphrase must already be unlocked (`ssh-add`). For a server by address, give the address and the access key. **Connection details** holds what few people type: the access key (the app finds it by itself on this Mac and over SSH), the port, and a name for the server. When the check fails, the window says what is wrong and the button reads **Try again**.
3. **Main bot.** Create the server's main bot: an avatar, a name, an **AI** and a **Model**. Or choose a bot that is already on that server. Instructions are added later, in the bot's settings.
4. **More bots.** Optionally choose a bot for each other AI the server has.
5. **Projects.** Optional, and only on a server that can add project servers. If your projects are on another server, add it here and name a first project; see [Projects on other servers](#projects-on-other-servers). To skip it, press the last button.

The window ends in the main bot's chat.

To look around without a server, close the setup window and choose **Look around with sample bots** in the main window. The sample bots answer locally.

More detail on the ways to connect: [Use the Mac app](../HerdrWorkspace/README.md#use-the-mac-app), and the drawing under [Where bots run](architecture.md#where-bots-run).

<a id="the-first-conversation"></a>

### 4. Say hello

A main bot that the setup window has just created opens the conversation itself. The chat shows one small line, "SwarmHub asked Jarvis to say hello" (with your bot's name), and the bot greets you, says what it can do, and asks a few short questions, one per reply:

1. what to call you,
2. what you work on,
3. what you would like help with first,
4. whether it should set up other bots for that,
5. whether any of your projects are on another server.

You can skip any question or stop whenever you like. The bot is told to do no other work until you ask for something.

When an answer tells the bot something lasting about you, a card above the composer says "Jarvis would like to remember this about you", with **Remember** and **Don’t save**. What you keep goes into **About you**, a short text (up to 800 characters) that every bot is given with its instructions, so no bot has to ask again. Read and edit it under **Settings → General**. Only a main bot suggests additions, and nothing is added without your OK.

A main bot that the setup window did not create (one from before, or one you chose to keep) offers this once, above its composer: "Let Jarvis get to know you", with **Start** and **Not now**. To ask for it later, choose **Get to know me** in the **+** menu of the main bot's composer.

## Everyday use

### Chat

Type a message and send it. The reply appears as the bot writes it, with each tool call as a step under it. Until there is text, the line under the reply says what it is waiting for: the AI is starting, the bot is working, a tool step is running, or the bot is waiting for you in its terminal.

Opening a chat starts that bot if it is not running, so the first reply does not wait for the AI to start. The header says **Starting …** and then **Ready**; **Ready** means a reply starts at once. You can write while it starts: the message is delivered as soon as the bot is ready. To turn this off for one bot, open its Details, **Model**, **Advanced**, and switch off **Keep _name_ ready**.

- **Stop** in the composer (**Chat → Stop Answer**, ⌘.) interrupts the answer. The bot stays open for the next message.
- A message you send while the bot answers goes into the running answer. If **Read new messages mid-answer** is off for the bot (Details, **Model**, **Advanced**), or the message has attachments, it waits and is sent when the answer ends.
- A row marked as not sent offers **Retry**.

<a id="change-a-model"></a>

### Change what a bot runs on

Open the bot's Details (⇧⌘I) and choose **Model** (⌘6). Pick the **AI** and the **Model**; both lists come from the server. A change applies the next time the bot starts. **Start fresh** makes it start over now on what you chose: the chat stays, and the bot forgets what was said in it. A bot that was started when you opened the chat and has not been written to yet is switched at once.

**New bots run on**, in **Settings → Servers**, chooses the AI that new bots start on.

### Bot settings

**Chat → Bot Settings…** (⌥⌘,) has the bot's avatar, name, instructions and **Notify me when it replies**. **Advanced** holds its role, **Main bot**, **Ask me before creating bots** (for a main bot), **Other bots can message it**, **Can use helpers**, and the projects it may use. What a bot runs on is in its Details, not here.

### Create more bots

- **File → New Bot…** (⌘N), or **+** at the top of the sidebar, creates a bot yourself.
- Ask the server's main bot for one; **New bot…** in the **+** menu of its composer starts the request for you. The main bot creates the bot or asks you first. A bot it suggests shows above the composer with **Create** and **Not now**. A bot it created by its own decision shows there with **Keep** and **Remove**.
- **Add a bot for each AI**, in **Settings → Servers → Connection**, adds one bot for each AI the server has that no bot uses yet.

### Bots that write to each other

A bot can write to another bot on its server by name. The app puts the message into that bot's chat as a card with the sender's face, and the reply back into the sender's chat, so you can read both sides. This happens while the app runs. Limits keep two bots from answering each other for ever; at a limit the bots are told to bring the matter to you. To stop a bot from getting such messages, turn off **Other bots can message it** in its settings, under **Advanced**. **Stop** in a bot's chat ends the exchanges it is part of.

### Helpers

A bot can hand parts of its work to helpers. They show under the bot in the sidebar while they run; select one to read its task, steps, replies and terminal. To choose what each difficulty runs on, open **Settings → Servers**, choose the server, then **Helpers**. To stop one bot from using helpers, turn off **Can use helpers** in its settings, under **Advanced**.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/dark/helpers-sidebar.png">
  <img src="screenshots/light/helpers-sidebar.png" alt="The sidebar: three helpers under the main bot, each with its model and state." width="280">
</picture>

### Skills

If [skillshare](https://skillshare.runkids.cc) is installed on the Herdr server, **Settings → Servers → Skills** lists the server's skill library, and so does the **Skills** tab of a bot's Details (⌘7). A switch turns a skill on or off for the AIs the library is shared with; the app then updates them. A bot picks up a change the next time it starts fresh. Skills belong to the server and its AIs, not to one bot. The app does not install or remove skills: use `skillshare` on the server for that.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="screenshots/dark/skills.png">
  <img src="screenshots/light/skills.png" alt="Settings: a server's skill library with a switch per skill." width="480">
</picture>

### Projects on other servers

Your projects may live on other servers than the one your bots run on. Open **Settings → Servers**, choose the server your bots run on, then **Projects**, and press **Add a server**.

1. Copy the line the app shows and paste it into `~/.ssh/authorized_keys` of the account on the project server.
2. Type the SSH address (such as `deploy@10.0.0.7`) and a short name, and press **Add server**.
3. The first time, the app shows the server's fingerprint. Compare it with the server's own (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on that server) and press **Trust this server**.
4. Press **Add its first project** (later **Add a project**) and give a name and the folder.

Then open a bot's settings, **Advanced**, or the **Overview** tab of its Details, and switch on the projects it may use. The bot can run commands and change files in those folders, so choose with care.

### Groups

**File → New Group…** (⇧⌘N) puts several bots in one thread. Write `@Name` to address one member; a message without a mention goes to every member.

### Files and voice

Drop or attach images, text files, PDF, RTF, DOC or DOCX files. Text and document contents reach the bot as text. Images are kept in the chat and are not sent to the bot.

For dictation, open **Settings → Voice**, paste a deAPI API key and press **Save key**. A microphone button then appears in every chat's composer. The transcript is added to the draft for you to review.

### Import from Grok Bot

When Grok Bot is on this Mac, **Settings → Servers** shows a **Grok Bot** card. **Import from Grok Bot…** there, or in the **+** menu at the top of the sidebar, reads Grok Bot's bots and history on this Mac. Each bot becomes a bot here with its old history as a read-only archive.

### More servers

**Settings → Servers → Add a server** adds another server: choose where it is, fill in its fields and press **Connect and add**. Each bot runs on one server. With more than one server, a bot's Details show **Server** under **Model**, **Advanced**.

### Updates

**Settings → Software Update** answers whether everything is up to date: the app, and for each server its workspace (the bridge) and Herdr Core. When something is behind, a line appears at the bottom of the sidebar, and the page has one button, **Update Now** or **Update All**, that installs what is ready: the servers first, then the app.

- The app updates through Sparkle. It checks once a day in the background; **Install updates automatically** is off unless you turn it on. An app run from source does not update itself.
- A server installs a new workspace itself, from a signed release. Only the workspace restarts; your bots keep running.
- Herdr Core is updated by Herdr's own updater, started from the server's ••• menu.

How this works, what is trusted, and the one-time install by hand on a server whose workspace cannot update itself yet: [Updates](updates.md).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘, | Settings |
| ⌘N | New Bot |
| ⇧⌘N | New Group |
| ⇧⌘O | Import Template |
| ⌘K | Quick Switcher |
| ⌃⌘S | Show or Hide Sidebar |
| ⇧⌘I | Show or Hide Details |
| ⇧⌘H | Show or Hide Hidden Chats |
| ⌘1, ⌘6, ⌘7, ⌘3 | Details: Overview, Model, Skills, Media |
| ⌘5 | Members, in a group |
| ⌥⌘↑, ⌥⌘↓ | Previous Chat, Next Chat |
| ⌥⌘, | Bot Settings |
| ⌘. | Stop Answer |
| ⌘/ | Keyboard Shortcuts |
| Return, ⇧Return | Send the message, start a new line |

## When something is wrong

- **"This Mac is not set up to run bots yet."** Herdr Core and the bridge are not running. Start both, then press **Try again**.
- **The access key is refused.** The key in the app is not the one the bridge runs with. Empty the access key field so the app reads the key again, or paste the current one. The field is under **Connection details** in the setup window and under **Advanced** in **Settings → Servers → Connection**.
- **The bridge answers without Herdr Core.** Start Herdr Core on that machine.
- **The server has no AI to start.** Add an agent template to Herdr Core.
- **A reply never arrives.** The bot may be waiting at a prompt in its terminal; the chat header then says **Waiting for you in its terminal**. Answer it in the browser workspace or with `hc attach`.
- **"This server needs an update."** Open **Settings → Software Update**. A server whose workspace cannot update itself yet needs one install by hand: [First install on a server](updates.md#first-install-on-a-server).

<a id="build--contribute"></a>

## Build and contribute

See the [technical reference](reference.md) for the build, and [Architecture](architecture.md) for how the parts fit together.
