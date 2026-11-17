# SwarmHub for Herdr Core

This browser preview brings SwarmHub’s agent roster, task composer, and details panel to a Herdr Core workspace. The Rust service talks to the Core’s Unix socket using its generation 1 JSON-RPC protocol. The SwarmHub Mac app talks to the same service ([Use the Mac app](#use-the-mac-app)).

Agents and groups stay near the top of the roster. Open **Workspace tools** below them for Library, routines, skills, connections, approvals, and imports. Search and **Needs attention** stay visible above the roster.

The workspace starts agents from templates installed on the Core and displays the current terminal screen. It saves the tasks you submit and their delivery states across reloads and server restarts. Use **Save snapshot** to capture the current screen with a title. **Library** lets you reopen snapshots and saved conversations after the agent ends or Core goes offline. Follow-up tasks, interrupt, and end session go through the Core.

From an agent’s **Details**, choose **Agent library** to see the newest results from all sessions of that profile. Filter by **Pages**, **Files**, or **Snapshots**. The results stay available after a session ends or while Core is offline. Choose **Workspace library** to return to the full collection, including standalone Pages and archived conversations.

Choose **Create chat link** in a saved agent’s **Details** to bookmark its conversation. You can include up to 1,000 characters of draft text. That text is visible to anyone who can see the URL, but opening the conversation still requires workspace access. Opening the link fills an empty composer or holds the draft in the current tab for a new session. It leaves existing drafts alone and sends nothing automatically.

Use **Pin** beside a Page, file, or snapshot to keep it at the top of its Library lists. The same pin appears in the workspace Library and in the agent’s Library if the result belongs to an agent. **Unpin** returns it to its normal position. Pins stay saved when Herdr Core is offline.

Reloading the same browser tab keeps recent unsent direct and group drafts, including reply targets and group recipient selections. Reopen the conversation to continue. For group files that hadn’t been sent, select the named files again or choose **Continue without missing files** before sending. Drafts are stored in the current tab and cleared when the workspace locks or the access token changes.

Use **Download transcript** in a group or in **Library → Conversations** or **Grok Bot history**. The plain-text copy includes saved messages in order, even older messages outside the current view. It works with Herdr Core offline and lists file names without including their contents or terminal screens. Transcripts are limited to 16 MiB.

To switch from Grok Bot, use **Import from Grok Bot** in the roster. Choose your existing **SwarmHub Grok Export** folder or select its `bundle.json` files individually. The importer reads the files produced by [SwarmHub’s Grok Bot exporter](../scripts/export-grokbot.py) (`agentapp-bot-bundle/v1`). It works with Herdr Core offline and needs no Grok sign-in.

If you don’t have a bundle, open **I don’t have an export yet → Download local export helper**. Run `python3 ~/Downloads/swarmhub-grok-export.pyz` on the Mac that runs Grok Bot, or substitute the path where you saved the download. It reads only the local app cache, uses the existing export redaction rules, and creates a new private folder in Documents without replacing an older export. It needs no checkout, Keychain access, or Grok connection. The cache contains recent history only. Choose the folder the helper reports to review and import it.

Review the preview and select the bundles to import. Personal bots become saved profiles with standing instructions and read-only history. Groups become read-only archives. Find both under **Library → Grok Bot history** and search their messages with **Search workspace**. Re-importing the same bot adds missing messages in their original order and keeps your local profile edits. The bundles do not restore connector settings. When you start an imported agent, choose a Herdr template and review the stored instructions before opting to send them with the new task.

The current Grok Bot cache exporter does not capture private skills. If an older or supplied v1 export folder actually contains `SKILL.md` files listed in its root `index.json`, **Choose export folder** lists the available copies. Select the ones you want and choose **Prepare selected skill drafts**. In **Skills → Imported Grok skill drafts**, review and edit the instructions before saving them to your private library, or dismiss them. Re-importing the same skill name and instructions does not duplicate a saved or dismissed draft. The importer does not restore which Bot used a skill or run its instructions. For a separate written copy, use **Skills → Import skill file**.

The exporter records attachment names. If you have your own copies, put them in the `attachments/` folder next to the matching `bundle.json` and use **Choose export folder**. Some names change during export; use **View expected attachment names** in the preview to check what to call each copy. The preview shows how many matching files will be saved (up to 32 files and 8 MiB total per upload). Download saved files from the messages in **Grok Bot history**. Missing files stay marked as unavailable, and you can re-import the folder later to add them without replacing files you already saved.

Personal-bot routines from the export appear under **Routines → Imported drafts**. Existing exports usually contain only the routine names. If a bundle contains a supported schedule and instructions, the editor pre-fills them for review; other schedules require manual setup. Start the imported profile, choose **Set up routine**, and save using that agent’s running session. The routine starts paused with no run history. **Dismiss draft** only removes it from this list. Re-importing an older bundle can add drafts for the first time, and it won’t duplicate or restore drafts you already set up or dismissed.

## Try the demo

With a built bridge and `hc` on PATH, run this from `HerdrWorkspace` under an ordinary user account:

```sh
cargo build --locked
python3 dev/preview.py
```

Open the loopback URL it prints and enter the token from the indicated private file. The demo starts an isolated Herdr Core with two example agents, a group, and a Page. Try sending a follow-up. The example agents handle text locally and don’t use a model or connect to your accounts. Press **Ctrl+C** to stop the demo and remove its scratch files. Pass `--hc`, `--bridge`, or `--port` to override a path or pick a loopback port. Your existing Core and workspace remain separate.

## Run locally

Use Rust 1.89 or later, a C compiler for bundled SQLite, and a trusted, already running Herdr Core under an ordinary user account. Find the socket in the [Herdr Core endpoint documentation](https://github.com/herdrdev/herdr-core/blob/master/docs/security.md#state-and-endpoints) and add at least one [interactive agent template](https://github.com/herdrdev/herdr-core/blob/master/docs/templates.md).

```sh
cd HerdrWorkspace
cargo build --locked
export HC_SOCKET=/absolute/path/to/your/core.sock
export SWARMHUB_ACCESS_TOKEN="$(openssl rand -hex 32)"
printf 'Workspace access token: %s\n' "$SWARMHUB_ACCESS_TOKEN"
./target/debug/swarmhub-herdr
```

To skip the manual setup, `dev/start-local.sh` starts an installed bridge (`~/.local/bin/swarmhub-herdr`) against the default Core socket and keeps a generated token in a private file under `~/.config/swarmhub-herdr/`.

Set `SWARMHUB_AGENT_CWD` to an existing absolute directory to start every new agent there. Without it, agents start in Core's own working directory, which is often the home directory. Open each agent program once in that folder first: Claude Code asks whether to trust a new folder, and its default answer exits.

Open `http://127.0.0.1:8787` and enter the token. Use `SWARMHUB_PORT` to choose another loopback port. On a remote development machine, access that loopback port through your existing secure tunnel. The service does not start the Core, accept a public listener address, or expose a general JSON-RPC proxy. The token authorizes the browser to act on your behalf in this development workspace. Give it only to users you trust to run work on the Core account.

Only agents launched here appear in the roster. Core keeps live processes running when you close the tab or restart the Rust service. The live screen can overwrite earlier output as it changes; saved snapshots preserve exactly the text captured at that moment. The conversation records submitted tasks, recorded replies from opted-in agents, and manual snapshots. Agents that do not publish program status appear as running, with no status reported.

Choose **Take over** in **Agent output** to attach an interactive terminal to a running agent. The read-only output starts folded once the chat has a saved reply; choose **Show output** to expand it. Use the terminal to answer prompts or take control of work that needs your attention. **Detach** closes the viewer and leaves the agent running. This uses Herdr Core’s framed terminal protocol; it does not add a graphical desktop or override the agent’s permissions.

The journal is a private SQLite database at `$XDG_STATE_HOME/swarmhub-herdr/workspace.sqlite3` (default: `~/.local/state/swarmhub-herdr/workspace.sqlite3`). Set `SWARMHUB_DATA_DIR` to choose another private directory on local storage. Run only one bridge per data directory. SQLite uses write-ahead logging so agent helpers can save replies while the workspace reads history. Routine scheduling and automatic file collection use their own connections and wait for a later poll if another writer is busy. Use SQLite's backup command (`.backup`) for a live backup; copying just `workspace.sqlite3` can miss recent commits. The journal stores tasks, opted-in replies, captured terminal text, and published files in plaintext, so treat it as you would the agent workspace. An interrupted delivery is marked unconfirmed on restart and is never replayed automatically.

Use the same build of `swarmhub-herdr` for the bridge and the helper commands in your Herdr templates.

Choose **Appearance** in the sidebar to use **System**, **Light**, or **Dark**. System follows the device’s theme as it changes. Your choice is remembered in the browser or installed web app where you set it. It does not change another device or your workspace account. The generic offline page follows the device theme.

## Use the Mac app

The SwarmHub Mac app chats with the same agents through this bridge. Keep the bridge running on the machine that runs Herdr Core. The app keeps a list of Herdr servers, and each bot runs on one of them.

### Connect a server

The setup window opens on first launch; later, use **Settings → Set up…** or **Settings → Advanced → Servers and keys → Add a Herdr server**. Choose where Herdr runs:

| Choice | What you enter | What the app does |
| --- | --- | --- |
| **This Mac** (the default) | Nothing | Looks for the bridge on `127.0.0.1:8787` and reads its access token from `~/.config/swarmhub-herdr/token`. If nothing answers, it says so and shows the start command. The app does not install or start Herdr Core or the bridge yet. |
| **A server I reach over SSH** | The server's name, and optionally a login name and the path of an SSH key file | Runs `ssh -N -L` itself to forward the bridge's port, reopens the forward when it drops, and reads the access token from the server's `~/.config/swarmhub-herdr/token`. |
| **A server by address and access key** | The address of a port you forwarded yourself, and the access token | Connects to that address. |
| **Get a ready-made server from us** | Not available yet | Nothing. The row is a placeholder. |

**Test** checks the connection and says what is wrong when it fails: nothing answers, the access key is refused, the service answers without Herdr Core, or Core has no template to start an agent from. The setup window then asks for the server's main bot (a new one with a name, instructions, avatar, agent program and model, or a bot already on that server) and offers one optional bot for each other agent program the server has. Each bot begins on the first model the server lists for its agent program. In Settings, **Add starter bots** adds one bot per agent program later.

The SSH choice uses the system `ssh` in batch mode:

- Your `~/.ssh/config`, agent, and known hosts apply. A key with a passphrase must already be in the agent (`ssh-add`), because the app can't prompt for one.
- The app saves the key file's path, never the key. Access tokens are kept in the Keychain.
- A server seen for the first time is trusted and remembered, as if you had answered “yes” at the prompt. A server whose key later changes is refused.
- The forward uses the same port number on both ends, because the bridge checks it. Two servers that use the same bridge port can't be connected at once; give one a different `SWARMHUB_PORT`.
- The forward closes when you quit the app.

To forward the port yourself for the address choice, keep the port number the same on both ends:

```sh
ssh -L 8787:127.0.0.1:8787 your-server
```

### Bots

A new bot runs on Herdr. Open its settings and choose **Advanced → Herdr agent** to pick its agent runtime and model, and its server when you have more than one. The same controls are in the Details panel's **Model** tab.

The first message starts an agent on the server, named after the bot. Later messages go to that running agent, which keeps its own context, model, tools, and permissions. A new agent gets the bot's instructions once, before your first message. A Claude Code template that ends in `run-claude --workspace-preview` shows its reply growing a few lines at a time. A Codex template that ends in `run-codex` shows its reply growing a few words at a time. For both agents, each tool call shows as a step under the reply while it runs. **Stop** presses the agent's interrupt key and leaves it open. A message you send while the agent answers is typed into the running agent (steer); turn that off per bot under **Herdr agent** to hold the message until the answer ends. **Start a fresh agent** ends the running agent, so the next message starts a new one on the chosen runtime and model.

The app sends text only. An attached text file or document goes as text inside the message; an attached image stays in the chat and is not sent to the agent. The workspace's approvals, routines, and Library are not in the Mac app. Use the browser workspace for them, or `hc attach` to answer a prompt in the agent's terminal.

### Let the main bot create bots

Each server has one main bot: the bot whose **Advanced → Main bot → Main bot of …** switch is on. Ask it for a new bot. It answers with a name, an avatar, and instructions, and either creates the bot on its own decision or asks you. A bot it asks about shows above the composer and is added only when you choose **Create**. Turn on **Ask me before creating bots** to confirm every bot. A bot the main bot created on its own decision is listed above the composer with **Remove**.

Any other bot that wants a new bot asks the main bot. The app passes the request into the main bot's chat and the answer back into the asking bot's chat.

The new bot runs on the same server, with the same runtime and model as the main bot unless the request names another agent program. A Herdr bot is a record in the app, so nothing is created on the server until the new bot gets its first message.

### Helpers in the app

A bot is told how to start helpers ([Let an agent start helpers](#let-an-agent-start-helpers)) unless its **Advanced → Helper agents → Can start helper agents** switch is off. Running helpers show under the bot in the sidebar, and each opens as a read-only view of its task, tool calls, replies, and terminal. **Settings → Advanced → Servers and keys** reads and edits the server's helper settings.

### Stores from older versions

Older versions also ran bots on two other backends, which were removed. When the app opens a store that holds such bots, it first copies the file as it was to `store.json.before-herdr-only-<time>` beside it, then loads and saves the store without those bots and tells you once how many were left out and where the copy is.

## Install the browser workspace

Open SwarmHub on a device that can reach a secure workspace address. In the roster, choose **Install workspace** for instructions or use the browser’s install option when it’s offered. On [iPhone or iPad](https://support.apple.com/en-az/guide/iphone/iphea86e5236/26/ios/26), use Safari’s **Share → Add to Home Screen**, turn on **Open as Web App** if shown, and choose **Add**. In [Chrome on Android](https://support.google.com/chrome/answer/9658361?co=GENIE.Platform%3DAndroid), use the menu’s **Install** or **Add to home screen** option.

The app icon opens the same Rust workspace and uses the existing access token prompt. The bridge still listens only on loopback: its desktop `localhost` URL won't connect from a phone without separately configured, trusted access from that phone. The web app does not change the existing native Swift app. If the phone cannot reach the workspace server, the service worker can show a connection message. It does not cache conversations, files, API responses, tokens, or drafts, and installation does not add push notifications.

## Choose an agent and model

**New agent** and **Start new session** list the templates installed in Herdr Core. Search by agent program, template, description, or configured provider or model. A template can set a fixed model or offer choices at launch. The agent program handles sign-in and provider access.

To show provider and model names, add a `runtime-catalog.json` file next to `workspace.sqlite3`. Each key must be the name of an existing Herdr template without its `.md` extension. The agent program name (`harness`) is required; `provider` and `model` are optional. Replace these sample names with the labels that match your templates:

```json
{
  "codex-work": { "harness": "Codex", "provider": "OpenAI", "model": "Your configured GPT model" },
  "claude-work": { "harness": "Claude Code", "provider": "Anthropic" },
  "local-work": { "harness": "OpenCode", "provider": "Local endpoint", "model": "Your configured local model" }
}
```

The `provider` and `model` fields are display labels for a template's default. Keep credentials in the agent's own configuration. SwarmHub recognizes a few common direct commands without showing the command or its arguments, and still lists custom templates with no catalog entry. Changes to the catalog apply to future launches. Session details retain the launch choice and labels, including after Core disconnects.

For built-in model choice support, use a direct `/absolute/path/to/swarmhub-herdr` template command with one of these endings:

| Agent | Template command ending | Model IDs |
| --- | --- | --- |
| Codex | `run-codex` | Models available from the provider configured in Codex |
| Claude Code | `run-claude` | [Claude Code aliases or model IDs](https://code.claude.com/docs/en/model-config) |
| OpenCode V2 | `run-opencode mini` | The `provider/model` IDs shown by `opencode models` |

Templates can also put `--workspace-approvals` immediately after `run-codex`, `run-claude`, or `run-opencode`. Keep fixed model flags and other agent arguments in separate templates, or set defaults in the agent's own configuration. Add a `models` list under the template name in `runtime-catalog.json`, using the IDs available in your setup:

```json
{
  "codex": {
    "harness": "Codex",
    "models": [{ "id": "your-configured-model", "label": "Review model", "provider": "OpenAI" }]
  },
  "claude": {
    "harness": "Claude Code",
    "models": [{ "id": "sonnet", "label": "Sonnet", "provider": "Anthropic" }]
  },
  "opencode": {
    "harness": "OpenCode",
    "models": [
      { "id": "local/fast-model", "label": "Fast local model", "provider": "Local" },
      { "id": "hosted/review-model", "label": "Review model", "provider": "Hosted" }
    ]
  }
}
```

For other agent programs, add `"model_transport": "environment"` and a `models` list to the template's catalog entry. Herdr passes the selected ID in `SWARMHUB_MODEL_ID`. The template's entrypoint reads that value and passes it to the agent using the flag or setting it expects. An empty value means use the agent’s default. For example, an entrypoint for a program that accepts `--model` could use:

```sh
#!/bin/sh
if [ -n "$SWARMHUB_MODEL_ID" ]; then
  exec /path/to/your-agent --model "$SWARMHUB_MODEL_ID" "$@"
fi
exec /path/to/your-agent "$@"
```

In the launch dialog, use the agent’s default, choose a named model, or select **Enter a model ID**. The exact ID option works with eligible Codex, Claude Code, and OpenCode V2 templates even if there is no catalog entry. For OpenCode, enter `provider/model` as shown in its model list. Custom templates can enable exact IDs with `"model_transport": "environment"` without listing any models. The built-in integrations pass the ID as `--model`, or when OpenCode API first-task delivery is enabled, select it when creating the session. A custom entrypoint reads `SWARMHUB_MODEL_ID`. Starting another session from a profile suggests its previous ID when the template still supports model selection. The agent runtime determines whether the model is available and uses its own provider credentials. The choice applies to the new session.

For an OpenCode V2 template, set `"discover_models": true` in its catalog entry to show **Load OpenCode models** in the launch dialog. This requires a literal `swarmhub-herdr run-opencode mini` template and a Herdr Core that supports `machine.exec`. Templates may include `--workspace-approvals` and `--api-first-task`, in that order before `mini`. Discovery runs [OpenCode’s model listing](https://opencode.ai/docs/cli/commands#models) in Herdr’s working directory with its environment and any literal assignments at the start of the template command. The list reflects the providers and model configuration that OpenCode sees there; it does not test inference or verify provider access for each model. You can still type a model ID or use the agent’s default.

Set the same catalog flag on a literal `swarmhub-herdr run-codex` template (optionally with `--workspace-approvals`) to show **Load Codex models**. SwarmHub asks Codex’s [app server for its model catalog](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server) and uses each model’s exact launch ID. Codex can return a bundled or cached catalog, so a listed model does not confirm access for the current account or provider. SwarmHub does not request account data or run inference to populate the picker. The default and manual ID options remain available.

## Let an agent start helpers

A running agent can hand one task to another agent: a helper. The agent says how hard the task is; you decide what each difficulty runs on. Helpers stay off until the workspace has a helper policy: a `helper-policy.json` file next to `workspace.sqlite3`. Write it by hand, or save it through `/api/helper-policy` ([For apps](#for-apps)):

```json
{
  "max_running": 3,
  "stop_after_seconds": 60,
  "stop_unanswered_after_seconds": 1800,
  "difficulties": {
    "easy": { "template": "claude-work", "model": "sonnet" },
    "medium": { "template": "codex-work", "model": "your-configured-model" },
    "hard": { "template": "claude-work", "model": "opus" }
  }
}
```

- Each difficulty names an installed Herdr template and a model ID that template accepts (see [Choose an agent and model](#choose-an-agent-and-model)). Leave a difficulty out to refuse it.
- `max_running` is how many helpers one agent can have running at once, from 0 to 16.
- `stop_after_seconds` is how long a helper stays after it answers, from 5 to 86400. Leave it out for 60.
- `stop_unanswered_after_seconds` is how long a helper may go without answering its task, from 60 to 604800. Leave it out for 1800.

The workspace reads the file again for every request, so an edit applies to the next helper without a restart. A file it cannot read as a policy turns helpers off; the agent is told so.

Tell an agent about the command in its task or standing instructions, for example: “For a self-contained subtask, run `swarmhub-herdr helper start --difficulty easy|medium|hard "TASK"`, then `swarmhub-herdr helper wait NAME` for the answer.” The agent runs these in its own terminal:

| Command | What it does |
| --- | --- |
| `swarmhub-herdr helper start --difficulty easy\|medium\|hard [--name NAME] [--here] TASK` | Starts a helper and gives it the task. `-` as the task reads standard input. The helper starts in the folder where the workspace starts every agent; with `--here` it starts in the folder the command runs in. |
| `swarmhub-herdr helper list` | Lists the agent’s running helpers, and names the ended ones whose answers it can still read. |
| `swarmhub-herdr helper wait NAME [--seconds N]` | Waits for the helper’s answer (100 seconds unless you say otherwise), then prints it. |
| `swarmhub-herdr helper read NAME [--lines N]` | Prints the helper’s latest answer, also after the helper has ended, or the last lines of its terminal screen. |
| `swarmhub-herdr helper send NAME TEXT` | Gives a running helper a follow-up. |
| `swarmhub-herdr helper stop NAME` | Ends the helper now. Its answer stays readable. |

The agent chooses the difficulty, the task, an optional name and, with `--here`, the starting folder. The agent cannot choose the template or the model: the command has no option for them, and the workspace takes both from the policy. The workspace also refuses:

- an unknown difficulty, or one the policy leaves out;
- a helper that tries to start its own helpers;
- a start that would give one agent more than `max_running` running helpers.

### When a helper goes away

The workspace stops a helper in two cases:

- It answered and has stayed idle for `stop_after_seconds` since the answer was saved. A follow-up sent before then keeps it, and the time counts again from its next answer.
- It has not answered `stop_unanswered_after_seconds` after its task was sent, whether it waits at a prompt or is still working. A follow-up is a new task and starts this time again. `helper list` and `helper read` say that it was stopped without an answer.

Herdr Core also ends a helper when the agent that started it ends.

A helper that has ended no longer counts toward `max_running`, and it leaves the helper list and the workspace’s list of agents. Its conversation stays in the history, and the agent can still read its answer with `helper read NAME`. All of this is worked out from the saved replies and Herdr Core’s terminals, so it holds across a workspace restart.

### How the command reaches the workspace

The command talks to the running workspace over a local socket. Claude Code runs it as is.

Codex runs shell commands in a sandbox that refuses every connection, so there the command leaves its request as a file in `.swarmhub-helpers`, inside the folder the workspace starts agents in (`SWARMHUB_AGENT_CWD`), and the workspace answers with a file beside it. This needs no change to Codex’s settings.

- The files never hold the agent’s launch key. A request names the agent by a hash of the key and is signed with it, and so is the answer. A copied or old request is refused.
- A helper asked for this way starts a moment after the command returns, not before. The start command says “Starting”, and `helper wait` reports a start that failed.
- Without `SWARMHUB_AGENT_CWD` there is no such folder, and a sandboxed agent cannot use helpers.

Either way, if the workspace server is not running, the command changes nothing and says so.

### Known limits

- With `--here`, the agent program may not have been trusted in that folder. The helper then stops at the program’s trust prompt and its task is not delivered. The command says so, the helper still counts as running, and a person answers the prompt in the helper’s terminal.
- Trust the agents’ folder in Codex once before Codex agents use helpers. While Codex runs a shell command, it keeps placeholder folders such as `.git` in its working folder, and a Codex agent started in an untrusted folder at that moment asks whether to trust it and gets no task. Without the trust, a Codex helper of a Codex agent stopped at that prompt about every second time. Claude Code helpers are not affected.
- A helper is stopped after its answer even when it left work running in the background and meant to come back. Its first message tells it to answer only when everything is done; raise `stop_after_seconds` for helpers that do long jobs.
- A helper that works on one task for longer than `stop_unanswered_after_seconds` is stopped in the middle of it. Raise that number for long jobs.
- The policy governs what the helper command starts. An agent with a shell can still run other programs itself, so use the agent’s own permission settings to limit that.

### For apps

A helper is an ordinary session: its replies, tool activity, terminal and history work as for any agent. It has no profile of its own.

- `GET /api/agents/{address}/{created_ms}/events` sends the same list whenever it changes ([Follow a session without polling](#follow-a-session-without-polling)).
- `GET /api/agents/{address}/{created_ms}/helpers` lists an agent’s running helpers, newest first, with each one’s name, difficulty, template, model, task, status and latest saved reply, plus `limit`, `stop_after_seconds` and `stop_unanswered_after_seconds`.
- In `/api/workspace`, a running helper carries `parent` with the address and creation time of the agent that started it.
- `GET /api/helper-policy` returns `policy` (the file’s four fields, or `null`), `problem` (why helpers cannot start as things are, or `null`) and `bounds` for the three numbers.
- `POST /api/helper-policy` takes the policy as its body and saves the file. It answers like `GET`, or with status 422 and an `error` when a number is out of bounds, Herdr has no such template, or the template cannot take the model.

## Work on projects on other servers

Your projects may live on other machines than the one Herdr runs on. Add each such machine once as a project server, name the folders on it that matter as projects, and say for each bot which projects it may use. A bot then runs commands and changes files in a project with one command, and never needs the host or the path.

Herdr Core does the connecting: a project server is a machine as in Core’s `hc machine add` (see `docs/machines.md` in Herdr Core). The workspace adds the app’s side of it, the list of projects, and the command for agents.

### Add a project server

1. Give the project server the Herdr server’s public key. `GET /api/machines/ssh-key` returns it; paste the line into `~/.ssh/authorized_keys` of the account to log in as on the project server. If the Herdr server has no key pair yet, `POST /api/machines/ssh-key` makes one.
2. Add the server by the address ssh takes, such as `deploy@10.0.0.7` or `deploy@10.0.0.7:2222`, and a short name to call it.

What to know:

- Logging in works with a key or not at all. Nothing here takes a password or a one-time code, and nothing waits for someone to type one.
- The first time the Herdr server connects to a host, ssh does not know the host’s key. The workspace does not trust it silently: adding answers `unknown_host_key` with the fingerprints the host shows. Compare one with the server’s own (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the project server) and add the server again with `accept_host_key` set to it. The workspace then writes that one key into the Herdr account’s known-hosts file (the first `UserKnownHostsFile` ssh names for that host, with the host’s name in the clear), and from then on ssh refuses the host if it ever shows another key. A host whose key differs from one already on file is refused, and the workspace does not replace the key.
- Adding copies Herdr’s helper program, `herdr-core`, to `~/.local/bin` of that account on the project server when it is missing or too old, and starts it there. That is what `hc machine add --install` does. Nothing else is installed.
- Removing a server only makes Herdr forget it. The helper program stays there, and so does anything it runs. A server that still has projects is not removed.
- The list says for each server whether it is connected and carries Core’s warnings in words. One of them: on a Linux server without lingering, programs started there stop when the last login ends; the warning names the `sudo loginctl enable-linger` command that fixes it.
- A key pair the workspace makes is Ed25519, has no passphrase, and is saved as `~/.ssh/id_ed25519` with the private half readable by the account alone. It gets that name because Herdr Core runs plain `ssh`, which tries that file by itself; a key under another name would need an entry in `~/.ssh/config`. The workspace makes a pair only when the account has none of the key files ssh tries by itself, never replaces one, and never returns a private key.
- The workspace shows the keys ssh uses by default. If `~/.ssh/config` names another key for a host, ask with `?target=` to see the key for that host. Keys held only by an SSH agent are not shown.

### Name projects and choose who may use them

A project is a name, a server, a folder on it, and an optional note for the bots, such as “staging only”. Adding one asks the server whether the folder exists, so a project is never saved for a folder that is not there. The check needs a POSIX `test` command on the server.

A bot may use the projects its launch names (`projects` in `POST /api/agents`) and nothing else; the list can be changed while it runs. A helper uses the projects of the agent that started it. An agent started with projects is told in its first task which ones it has and to run `swarmhub-herdr project list`.

This is guidance and bookkeeping, not isolation. All agents run as the workspace’s account, that account can log in to every project server, and an agent with a shell that is not sandboxed can run `hc` or `ssh` itself. The list decides what the `project` command does for an agent. To keep an agent away from a server for real, do not add that server to this Herdr, or limit the agent with its own program’s permission settings.

### What a bot runs

| Command | What it does |
| --- | --- |
| `swarmhub-herdr project list` | Lists the agent’s projects with each one’s server, folder, note and whether the server is connected. |
| `swarmhub-herdr project run NAME [--timeout SECONDS] -- COMMAND [ARG...]` | Runs a command in the project’s folder on its server, prints what it wrote, and exits with its exit code. One word after `--` is a line for that server’s shell, such as `"cd src && make test"`; several words are a program and its arguments as given. |
| `swarmhub-herdr project read NAME PATH [--offset LINE] [--limit LINES]` | Prints a text file, or lines of it. |
| `swarmhub-herdr project write NAME PATH` | Writes standard input as the file, making missing folders. |
| `swarmhub-herdr project edit NAME PATH --old TEXT --new TEXT` | Replaces a text that is in the file exactly once. Repeat the pair for several replacements; all are made or none. |

- A command runs for 120 seconds unless `--timeout` says otherwise, at most 600. When time is up it is ended with everything it started, and the command exits with 124. For longer work, start it in the background on the server and look at it later.
- One answer carries 96 KB of a command’s output and 24 KB of what it wrote to standard error. Longer output keeps its start and its end and says what was left out.
- `read` gives at most 2000 lines and 100 KB at a time and says how to continue. `write` takes up to 128 KB of text. Files that are not text are handled on the server with `run`.
- `PATH` is inside the project’s folder: `src/main.rs`, not `/etc/hosts` and not `../x`. This keeps mistakes out; it is not a wall, since `run` can do anything the account can.
- After a command, a line on standard error says where it ran and how it ended: `[project shop on box: exit 0 after 0.4 s]`. When the `project` command itself could not do its work, it says why and exits with 125.

The command reaches the workspace the same way `helper` does ([How the command reaches the workspace](#how-the-command-reaches-the-workspace)), so it works in Claude Code and in Codex’s sandbox alike. Herdr’s own `hc run --on` does not work in Codex’s sandbox, which refuses the connection to Herdr Core. What an agent runs with `project run` runs on the project server, outside that sandbox and without the agent program’s permission prompts.

### For apps

Every route needs the access token. A refused request answers with `error`, words to show as they are, and for the cases in the tables below with `kind`, a word to act on. A failure of Herdr Core itself, such as Core not running, answers as on every other route, with `error` alone.

Servers:

- `GET /api/machines` returns `machines`, `can_add`, `problem` (why a server cannot be added from this workspace, or `null`) and `adding` (a sentence about the helper program). Each machine has `name`, `target`, `host` (what it calls itself), `version` (its helper’s), `state` (`connecting`, `connected`, `needs_login`, `needs_update` or `unreachable`), `reachable`, `since_ms`, `why`, `keeps_running_after_logout`, `warnings` (sentences) and `projects` (names), plus Core’s own `session`, `via` and `temporary` for machines that were added with `hc` on the server.
- `POST /api/machines` takes `{"target": "deploy@10.0.0.7", "name": "box"}`; `name` may be left out, and `accept_host_key` takes a fingerprint this route offered. It answers 201 with `machine`, `helper_installed` and `message`. It can take a few minutes when the helper is copied.
- `POST /api/machines/remove` and `POST /api/machines/connect` take `{"name": "box"}`. Remove answers like the `GET` plus `removed`. Connect has Herdr try the server now, for after the key was pasted, and answers with `machine`.
- `GET /api/machines/ssh-key` returns `keys`, `can_create`, `where_to_paste` and `problem`. Each key has `public_key` (the line to paste), `type`, `fingerprint`, `comment` and `file`. With `?target=deploy@10.0.0.7` it gives the keys ssh would use for that server.
- `POST /api/machines/ssh-key` makes the key pair when `can_create` is true and answers 201 like the `GET`.

| Status | `kind` | Meaning |
| --- | --- | --- |
| 409 | `unknown_host_key` | ssh has not seen this host. `host_keys` lists `type` and `fingerprint` of each key it shows; send one back as `accept_host_key`. The list is empty when the workspace could not read the key, and `error` says what to do by hand. |
| 409 | `host_key_changed` | The host shows another key than the one on file. Nothing is changed. |
| 409 | `login_refused` | The server refused the Herdr server’s key. |
| 409 | `name_taken`, `already_added`, `has_projects`, `key_exists` | The name is in use; this server is already added; the server still has projects; the Herdr server already has a key pair. |
| 404 | `machine_unknown` | Herdr has no machine by this name. |
| 422 | `invalid` | The body is not the expected one. |
| 502 | `unreachable` | ssh could not connect; `error` carries what ssh said. |
| 502 | `helper_not_installed` | The login worked, and the helper program could not be installed or started there. |
| 502 | `failed` | Herdr Core refused for another reason; `error` carries what it said. |
| 503 | `unavailable` | The workspace cannot find `hc` or `ssh` on its `PATH`. |
| 504 | `timeout` | Adding took more than 300 seconds and was stopped. |

Projects:

- `GET /api/projects` returns `projects`. Each has `id`, `name`, `machine`, `folder`, `note`, `created_ms`, `machine_state` (the server’s state, `missing` when Herdr no longer has a machine by that name, `unknown` when Herdr Core could not be asked) and `reachable`.
- `POST /api/projects` takes `{"name": "shop", "machine": "box", "folder": "/srv/shop", "note": "…"}` and answers 201 with `project`.
- `POST /api/projects/{id}` takes any of the four fields and answers with `project`. `POST /api/projects/{id}/remove` answers with `removed` and the remaining `projects`.
- `POST /api/agents` takes `projects`, a list of project ids, for the new agent.
- `GET /api/agents/{address}/{created_ms}/projects` returns `projects` and `inherited` (true for a helper). `POST` there takes `{"projects": [1, 2]}`, replaces the agent’s list and answers like the `GET`; an empty list takes all projects away.

| Status | `kind` | Meaning |
| --- | --- | --- |
| 404 | `project_unknown` | No project has this id. |
| 409 | `name_taken` | Another project has this name. |
| 409 | `machine_unreachable` | The server is not connected, so the folder could not be checked. Nothing was saved. |
| 409 | `helper` | A helper’s projects are changed at the agent that started it. |
| 422 | `invalid`, `machine_unknown`, `folder_missing`, `project_unknown` | The body is not the expected one; Herdr has no machine by this name; the folder is not on the server; a project id in a list does not exist. |
| 502 | `check_failed` | The server could not say whether the folder exists. |

### Known limits

- A project names its server by Herdr’s name for it. After `hc machine rename`, change the project’s `machine`.
- Projects on the Herdr server itself are not offered: an agent there works in its own folders, and the `project` command would let a sandboxed agent run commands outside its sandbox on that server.
- A server reached through a jump host or a custom command can be added with `hc machine add` on the Herdr server and then shows in the list. The workspace cannot read such a host’s key, so it cannot offer `accept_host_key` for it.
- A Windows server can be a machine in Herdr Core, and the folder check here does not work for it.
- Changing a running agent’s projects does not tell the agent. Send it a message.

## Keep an agent profile

Choose **New agent**, enter a name, and save to open an empty conversation. You can create the profile and draft its first task while Herdr Core is offline. The draft stays in the current browser tab, including after a reload. When a template is available, choose **Choose runtime** to review the template and model before sending the task. Use **Start from template** if you prefer to choose the runtime before creating the profile.

Use **Runtime setup** to check the templates Herdr can load. It distinguishes a disconnected Core from an empty template folder or a template that needs attention. It also provides downloadable examples for Codex, Claude Code, OpenCode V2.3, and other interactive agents. Save a reviewed example in Herdr’s templates folder and choose **Refresh runtimes**. Choosing an available template from a saved profile’s first draft opens launch review with the draft intact. The panel does not install the agent or check provider sign-in.

Open an agent and choose **Details → Edit profile** to change its display name, label, or avatar. You can pin it at the top of the roster or hide it. Use **Show hidden agents** to find and restore hidden profiles. These settings are stored in SwarmHub; they leave the Herdr terminal name and running work intact.

The **Session** picker opens recent conversations, even when Herdr Core is offline. If no session is running for the profile, **Start new session** starts a fresh process and defaults to the last used template. Earlier conversations stay in the profile and Library. Groups, routines, and agent-specific skill availability still refer to their original sessions.

Choose **Details → Duplicate agent** to save a new profile with its own name. The copy keeps the avatar, label, standing instructions, and the latest session’s template, model choice, file collection preference, skill availability, and non-archived routines. You can create the copy with Herdr Core offline. When you start its first session, review the copied settings and enter a new task. Copied routines are paused and have no run history. Conversations, group memberships, and files stay with the original.

To move a profile between workspaces, choose **Details → Download agent template**. Review the display name, label, preset avatar, and standing instructions before downloading the JSON file. You can remove private text without changing the original profile. In the other workspace, choose **Import agent template**, pick the file, and review its settings before choosing **Create agent**. This creates an empty conversation even with Herdr Core offline. The file does not carry runtime settings, uploaded images, skills, routines, conversations, files, or credentials. Choose a runtime when you’re ready to start the new agent.

To use your own picture, open **Details → Edit profile**, choose **Uploaded image** under **Avatar**, and select a PNG, JPEG, or WebP up to 5 MiB. Use the preview and sliders to crop it, then save the profile. SwarmHub stores only the square thumbnail, without the original file or image metadata. You can change avatars while Herdr Core is offline. Switching back to a preset removes the uploaded picture from that profile.

Choose **Sections** in the roster to create, rename, or remove sections. Right-click an agent (or press **Shift+F10** on its roster entry) and choose a destination, or use **Details → Move to section**. Pinned agents stay at the top, hidden agents stay in their own view, and filtering by a section name finds its agents even when it is collapsed. Removing a section moves its agents to **Unsectioned**. Section names and assignments are saved in the workspace and can be edited while Herdr Core is offline.

Use **Standing instructions** in the profile editor or when starting from a template to keep a role, working preferences, or rules across sessions. To reuse something you wrote, choose **Save as standing instructions** on a task, then review and save the proposed edit. Choose **Add instructions to draft** in Details if you want to use them in a running session without sending immediately.

An agent can suggest a preference, correction, or instruction through `swarmhub-herdr propose-memory < memory.txt`. Use one line up to 512 bytes, with no passwords, keys, or tokens. The conversation shows **Review memory suggestion** without exposing its contents in the transcript. Edit the suggestion, dismiss it, or choose **Append to standing instructions** to save it to that agent profile. Review and approval work even if Herdr Core is offline. This flow never infers or saves a memory on its own.

When starting another session, review the saved text and uncheck **Include saved standing instructions** if you don't want it sent to that runtime. The instructions and first task together must fit within 16 KiB. The conversation shows the exact version attached to the launch; editing or clearing the profile affects future sessions and leaves past launch records alone. A fresh session receives these instructions without automatically replaying old chats or transferring model memory.

## Send and receive files

Use **Attach files** from a running agent’s composer, drop files onto it, or paste a screenshot into the task field. Review or remove up to four files totaling 8 MiB. When you choose **Send task**, Herdr stages the files and the task tells the agent where to find them. If a file cannot be staged, the task is held and you can edit the draft or try again. A reload remembers which files you chose and asks you to select them again or continue without them. Staging requires a Core with `terminal.put`.

Choose **Record voice memo** in a direct or group composer to record up to one minute. Stop the recording, listen to it, and choose **Add to draft** to keep it as an ordinary attachment. The audio stays in the browser until you send the message; reloading the tab clears the unsent recording. The microphone stops when you stop, discard the memo, or leave the conversation. Recording requires microphone capture from a secure browser context such as `localhost`. Whether an agent can understand the audio depends on its runtime.

Choose **Dictate** in a direct or group composer to turn speech into editable text. SwarmHub checks whether the browser can recognize the chosen language on your device. If it offers **Prepare language**, your browser may download a speech pack after you choose it. Dictation never falls back to cloud recognition. Browser, system, and language support vary; you can still type or record a voice memo if on-device recognition is unavailable. Stop, edit the transcript, and choose **Add to draft** to append it to what you already wrote. Only **Send** submits the message.

After sending, select a filename on the task to open its preview or download the original. These copies stay with the task in direct chats, threads, and archived conversations, even if Core is offline or the terminal copies are gone. Transcript downloads include filenames. Older direct attachments that were recorded only as terminal paths still show those paths.

To connect a WebDAV folder, start the bridge with `SWARMHUB_WEBDAV_URL` set to the final HTTPS collection URL. For Basic authentication, set `SWARMHUB_WEBDAV_USERNAME` and `SWARMHUB_WEBDAV_PASSWORD_FILE` to the account name and a private mode-0600 file containing its app password. An anonymous collection needs only the URL. For a private certificate authority, set `SWARMHUB_WEBDAV_CA_FILE` to its PEM certificate bundle. The bridge keeps these credentials out of the browser and agent environment.

You can store the app password in **Vault** instead. Generate a vault key once (`(umask 077; set -C; openssl rand -hex 32 > /private/path/vault-key)`) and point `SWARMHUB_VAULT_KEY_FILE` at that private file. Configure `SWARMHUB_WEBDAV_USERNAME` and `SWARMHUB_WEBDAV_VAULT_ENTRY` instead of the password file. Set the entry name to the one you’ll add in Vault, then start the bridge and save the password under that name. Replacing it applies to new requests without a restart; removing it stops the connection until you add a replacement.

Vault values are encrypted in the workspace database. The browser shows entry names and lets you replace or remove values, but never reads a saved value back. Keep a separate backup of the vault key; losing it makes existing entries unreadable. A different key cannot overwrite an existing vault. Vault does not inject credentials into Herdr sessions or sign in to websites on an agent’s behalf. It does not replace OS isolation for an agent that can access both the database and its key file.

Open **Connected files** to browse the folder, even while Herdr Core is offline. From a running agent’s composer, use **From connected folder** to add a copy to the draft. You can remove that copy before sending; SwarmHub stages it along with your other attachments when you send.

To connect Google Drive in the browser, enable the Drive API, configure the SwarmHub Vault key, and create a [Google Desktop OAuth client](https://developers.google.com/identity/protocols/oauth2/native-app). Put the following in a private mode-0600 JSON file and point `SWARMHUB_DRIVE_CREDENTIALS_FILE` at it:

```json
{"folder_id":"your-drive-folder-id","client_id":"your-client-id","client_secret":"your-client-secret","browser_oauth":true}
```

With the workspace reachable from your browser at `http://127.0.0.1:<workspace-port>`, open **Connected files → Connect Google Drive → Authorize with Google**. Use a Google account that can open the configured folder. Return to SwarmHub and choose **Check connection**. The callback uses the same loopback port. SwarmHub stores the refresh token in Vault. **Disconnect Google Drive** removes the token from this workspace and leaves Drive files alone. The browser setup requests read-only Drive access by default. If the configuration enables uploads, authorize again so Google can grant file creation permission.

For a headless setup, supply a refresh token with offline access and the `https://www.googleapis.com/auth/drive.readonly` scope instead of setting `browser_oauth`. See [Google’s OAuth server guide](https://developers.google.com/identity/protocols/oauth2/web-server#offline).

```json
{"folder_id":"your-drive-folder-id","client_id":"your-client-id","client_secret":"your-client-secret","refresh_token":"your-refresh-token"}
```

The bridge refreshes access on the server. Choose **Google Drive** in the file picker if both sources are connected. You can browse the configured folder and its descendants, attach original files, and attach Office exports of Google Docs, Sheets, and Slides. Shortcuts are omitted, and each attachment is limited to 8 MiB. The browser does not receive Google tokens. Browsing works while Herdr Core is offline.

To let a running agent read from that folder, open **Details → Google Drive access → Allow read access for one hour**. SwarmHub associates the grant with the selected session until expiry, revocation, or workspace restart. Use it with agents you trust: processes sharing the workspace’s OS account can also access that account’s local files, including its SwarmHub journal. The agent can list folders or read files using the commands in the dialog from its Herdr session. Join folder and file IDs from the listing with `/`; `drive-read` writes the file bytes to standard output and exports Google Docs, Sheets, and Slides as Office files. There is no agent upload command. **Recent requests** shows completed and refused requests from that session. Reconnecting or disconnecting Google Drive removes all current grants. Revocation stops new requests; a file already being delivered to the agent can finish.

Google Drive is read only by default. To enable **Save to connected folder** for Drive, set `"allow_uploads":true` in the credentials file and use a refresh token with a [Drive scope that permits file creation](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) in the chosen folder. Select a writable folder, review the filename, and choose **Save copy here**. SwarmHub creates a new file up to 8 MiB, even if the folder already contains a file by that name. You can save copies of Library files and direct or group attachments while Core is offline.

The connection is read-only by default. To allow saving copies, set `SWARMHUB_WEBDAV_ALLOW_UPLOADS=1` and give the WebDAV account permission to create files. Open a saved **Library → Files** item or a group attachment preview and choose **Save to connected folder**. Select a folder, review the filename, and choose **Save copy here**. This works with Herdr Core offline and saves the original bytes, up to 8 MiB. The server must support conditional file creation: SwarmHub asks it to create the file only if the name is available. If that name already exists, choose a different one.

Select **Collect finished files in this conversation** when launching a session to give that agent its own results folder. The path appears in **Details** and is passed to the agent in `SWARMHUB_RESULTS`. Move completed files into the folder after writing them. SwarmHub collects stable, visible top-level files up to 8 MiB each, with a limit of 64 saved files or versions and 64 MiB total per session. Links, folders, and hidden drafts stay out of the Library. If a file changes, the new contents become a separate result; leaving the same file in place does not create another copy, even after restart. Collection resumes when the workspace starts again.

You can still ask an agent to publish a file explicitly with `/absolute/path/to/swarmhub-herdr publish-file /path/to/result`. Publication saves a copy of a regular file up to 8 MiB and creates a conversation card. Open the card, choose **Library → Files**, or select **Preview** on a group attachment. The viewer displays PNG, JPEG, GIF, and WebP images at fit or actual size, CSV tables with up to 50 data rows and 20 columns, and plain UTF-8 text up to 256 KiB. It also plays MP4 and WebM video and WAV audio when the browser supports the file’s codec. **Download file** returns the original bytes, including when playback is unavailable. The saved copy stays available after the agent, source file, or Core is gone.

PDFs open one page at a time. Use **Previous** and **Next** to navigate, and **Page text** to read or copy the text embedded on the current page. The preview renders locally without running document scripts or opening embedded links. Password-protected documents require downloading the original.

## Search the workspace

Choose **Search workspace** or press **Cmd/Ctrl+K**. Search agent and group names, saved direct, group, and imported messages, skill instructions, routines and their imported drafts, Page text, saved filenames, and snapshot titles. Filter by category, then use the arrow keys and Enter or choose a result. A message result jumps to the matching entry; **Latest messages** takes you back to the newest entries. A direct attachment opens its saved preview. Imported routine drafts open for review and stay inactive. Search uses saved workspace data and stays available when Core is offline.

## Browse a GitHub project

Set `SWARMHUB_GITHUB_REPOSITORY` to one GitHub repository in `owner/repository` form. For a private repository or authenticated reads, save a fine-grained token for that repository in the workspace Vault and set `SWARMHUB_GITHUB_VAULT_ENTRY` to its entry name. Grant only [**Issues: Read**](https://docs.github.com/en/rest/issues/issues?apiVersion=2022-11-28#list-repository-issues) and [**Pull requests: Read**](https://docs.github.com/en/rest/pulls/pulls?apiVersion=2022-11-28#get-a-pull-request). The connector uses the fixed GitHub REST API origin and makes read requests only.

Open **Workspace tools → GitHub project** to browse open issues and pull requests. Choose **From GitHub** in a direct or group composer to review and attach an excerpt as a text file. The attachment stays in the draft until you send the task. The browser does not receive the Vault token. Browsing still works when Herdr Core is offline; attaching requires a connected draft.

To let one running SwarmHub agent read an excerpt itself, choose **Details → GitHub read access → Allow read access for one hour**. The panel shows the exact terminal command for `github-read issue NUMBER` or `github-read pr NUMBER`. The command reads a bounded excerpt from an open item in the configured repository by number. It has no access to comments, diffs, arbitrary URLs, or write operations. The GitHub credential stays with the workspace; the panel shows only recent request types, numbers, times, and outcomes for that session.

The grant ends after an hour or when you revoke it, stop the session, restart the workspace, or replace its Vault credential. A grant is tied to one session. Processes running under the same operating-system account still share that account's privileges; use separate OS accounts for untrusted agents.

## Write and revisit Pages

Markdown task lists (`- [ ] Review` and `- [x] Done`) appear as interactive checkboxes in a Page. Checking an item saves a new revision and updates the Markdown download. This works with Herdr Core offline. If another edit won the race, choose **Reload latest revision** and try again.

Use **Library → Pages → New page**, or **Save as page** on an agent reply, to keep a report you can edit. Pages support Markdown headings, lists, tables, and code. Open a saved page to read it, edit it, or download its Markdown. Pages and their previews stay available when Herdr Core is offline.

Open **Filter or sort table** to find matching rows in one column or across the table. You can sort by a column in either direction and reset the original order. Each table has its own view. These controls work on retained revisions and leave the saved Markdown unchanged.

To make a chart, ask the agent to include a `chart` code block with JSON in the Page’s Markdown. For example:

```chart
{"type":"bar","title":"Launch tracker","unit":"tasks","points":[{"label":"Ready","value":8},{"label":"Open","value":3}]}
```

Use `bar` to compare values or `line` to show a trend in the order the points are listed. A chart can show up to 48 points; a line needs at least two. **Show chart data** lists the exact values. Charts render offline, and the Markdown download keeps the original data. If a block cannot be rendered, the Page keeps its source visible.

Open **Revision history** to see the latest 50 saved revisions. Earlier revisions open for reading and downloading. **Restore as new revision** copies the selected title and Markdown into a new revision, keeping the changes you made since then in the history. For Pages created before this feature was added, history starts with the revision that was current at upgrade.

Choose **Download shareable HTML** to save the revision you’re viewing as a read-only file. It opens in a browser offline with no workspace login. The copy includes the document, checked and unchecked items, tables, and exact chart values. It contains no scripts or external resources; links are printed as text. Sharing the file sends that fixed copy to the recipient and does not publish the live Page.

Choose **Copy workspace link** to bookmark a Page. A link copied from the latest view opens the latest revision; a link copied while viewing a specific revision opens that saved version. If the revision has aged out, the link offers to open the latest version. The URL contains no access token and opens only after the workspace is unlocked, including when Herdr Core is offline.

Choose **Share Page** from the latest revision to create a read-only viewer link for seven days. **This revision only** keeps the exact copy you reviewed, even if it later ages out of revision history. **Latest, including future updates** shows future edits to anyone with the link, including edits made by the agent. Readers can filter tables and view charts without changing the Page. They need to be able to reach the workspace address, but never need your workspace token. Copy the link when you create it; SwarmHub stores only a fingerprint. To stop access early, open **Share Page → Revoke viewer link**. Revocation does not recall files or text someone has already saved.

An agent launched by the workspace can publish a document with `swarmhub-herdr publish-page "Title" < report.md` using the full path to the workspace binary. SwarmHub adds an **Open page** card to that session's conversation. The same session can use `read-page PAGE_ID` to get the Markdown and revision, and `update-page PAGE_ID REVISION < report.md` to revise the document without replacing its card. Browser and agent saves check the revision before writing, so a stale edit cannot overwrite a newer one.

On an agent-published Page, open **Message about this page** to send a request to the original session. The side panel records the request and its delivery status; the full agent conversation contains its replies. A revision link beside the request opens the version it refers to while that revision is still in history. If the Page changes before you send, **Reload latest revision** keeps your draft and lets you review the new version. The original session must still be running to receive a request.

Pages start private to the workspace. Viewer links use the existing workspace address; there is no separate hosting service or team-specific sharing. Pages use the built-in controls.

## Reply to an earlier message

Choose **Reply** under a saved agent response, enter your follow-up, and choose **Send reply**. SwarmHub sends a short excerpt of that message alongside your text to the same running Herdr session. **Cancel reply** removes the quote and keeps your draft text. Saved replies retain the quote and a **View original** button; the button opens the archived conversation if the original is outside the messages currently shown. You can revisit that link with Herdr Core offline. Replies with quotes accept up to 14 KiB of new text.

Choose **Open thread** on a saved agent response or one of its follow-ups to see them together. Long originals open as a preview; choose **Read full original** to expand one. You can send another follow-up directly from the thread while the original session is running. If the agent uses the supplied reply command, its answer appears in the open thread and links to the exact follow-up. Threads remain readable from the conversation and the Library archive when Core is offline. Replies captured without that link still appear in the main conversation.

Choose **Hand off** on a saved direct or group reply to give another running agent a follow-up. Choose the agent, write the next task, and preview the source excerpt. **Open agent draft** appends the task and excerpt to the destination’s existing draft. Review, edit, and send from that conversation. The handoff copies text only and does not send a task on its own.

Saved agent replies in direct chats, threads, and groups can display Markdown headings, lists, tables, links, and code. Use **Show Markdown** for the original text or **Copy code** for a code block. Replies larger than 32 KiB, live previews, and imported Grok Bot history display as text. SwarmHub does not run HTML from replies or retrieve remote images.

## Review an email draft

An agent can suggest an email with `swarmhub-herdr propose-email < draft.json` from its own session. Use JSON with `to`, `subject`, and `body`, for example:

```json
{"to":"reviewer@example.test","subject":"Release review","body":"Could you review the release notes on Tuesday?"}
```

Choose **Review email draft** in the agent’s direct conversation to edit the recipients, subject, or message. Use simple addresses separated by commas, or leave **To** blank. **Download .eml draft** stores your edits on that same card and downloads a plain-text file you can open in your mail app. **Dismiss draft** removes the saved fields. These actions work while Herdr Core is offline. SwarmHub does not connect to a mail account or send the draft.

## React to a message

Choose **React** on a saved task or reply in an agent conversation, in its Library archive, or on a message in a group. Pick **Like**, **Thanks**, **Celebrate**, or **Looking**. Choose the reaction again to change or remove it. Reactions are kept with the message, work while Herdr Core is offline, and do not send anything to an agent. Imported Grok Bot conversations remain read-only.

## Work with a group

Choose **New group** (or `Cmd/Ctrl+Shift+N`), name it, and select two to six running agents. Pick recipients under **Send to**, type `@` to choose an agent, or use `@everyone` to select all running members. The composer shows the recipients before you send. **Edit group** changes the name or members while preserving the conversation and delivery records. A group is bound to one Herdr Core and its selected terminal sessions; you can still read the conversation if Core disconnects.

Use **Attach files**, drop files onto the composer, or paste a screenshot into the task field to add up to four files totaling 8 MiB to a group task. Files stay in the draft until you send. Herdr stages a copy in each selected session before sending its task. If staging fails for one recipient, that recipient does not get the task and its receipt explains why; other recipients can still receive it. Download the original copies from the group message even when Core is offline. As with other terminal files, staging does not change the permissions of the account running Herdr.

Group tasks bring along up to five recent group messages from tasks posted since the recipient joined. The task includes a one-use reply command scoped to its recipient, which the agent can run using its normal tools and permissions. Replies to previously delivered tasks can still arrive after a member is removed. Private agent replies and terminal output remain in the agent’s own view. Unconfirmed deliveries are not replayed after restart. Neither sharing with other users nor automatic agent-to-agent handoffs are part of this workflow.

Instead of a final reply, an agent can use the group task’s `group-handoff` command to suggest one follow-up for another current member. The command accepts JSON with `to` (one of the recipient names shown in the task) and `task` (plain text up to 4 KiB). Choose **Review handoff** to see the original group task, the fixed recipient, and an editable follow-up. **Send handoff** queues one Group task for that recipient. Opening or dismissing the suggestion sends nothing, and the resulting delivery can receive a normal reply without starting another agent handoff. Check the Group delivery receipt for the outcome.

While working, an agent can add `--draft` by itself to the reply command and pipe in a plain-text progress update of up to 2 KiB. The latest update for each recipient and task appears below the group conversation. It disappears after two minutes or when the agent posts its final reply. Updates do not go into the conversation history or the context sent to other agents.

New OpenCode V2.3 sessions using `--api-first-task` can also show **Live reply preview** for a group task while the agent is writing. The preview is attached to that recipient and task and shows up to 2 KiB of assistant text. It disappears when the live turn ends or a final group reply is posted. If OpenCode mixes inputs and SwarmHub cannot tell which task a step answers, the preview is withheld. The agent still uses the group reply command to post a saved answer. Claude Code and terminal templates can continue to post manual progress updates.

An agent can return a result with the same one-use `group-reply` command. Pipe the reply text to standard input and add `--file PATH` once per file. For a file-only reply, use empty standard input. A reply accepts up to four regular files totaling 8 MiB. SwarmHub saves the reply and its files together and shows the downloads on that reply, including after Herdr goes offline. Files returned this way stay with the group conversation.

An agent can add `--question` to its reply command and pipe in a short clarification. Use **Answer** on the question, or **Reply** on a regular agent message. SwarmHub sends that turn to the original session and shows the quoted message and delivery status in the group. It keeps the directed reply out of the context automatically supplied to other agents. A question can be answered again if delivery failed; pending, sent, and unconfirmed answers keep the question closed to prevent duplicate delivery.

An agent can use `--form` instead to request one to six fields, by piping JSON into the reply command:

```json
{"title":"Report preferences","fields":[{"key":"section","label":"Section","choices":["Summary","Timeline"]},{"key":"notes","label":"Notes","required":false}]}
```

Fields without `choices` accept short text. Fields are required unless they say otherwise. **Fill out form** submits the chosen values to the original agent session as JSON; the conversation keeps the values and their delivery status.

## Schedule routines

Open **Routines** in the sidebar or **View routines** from an agent’s details. Choose a running agent, provide instructions, and schedule them at an interval or at a daily or weekday time in an IANA time zone such as `Europe/Warsaw`. On a clock change, a duplicated local time runs once at its first occurrence; a missing local time moves to the first valid minute that day when available.

The workspace service schedules runs while it is running, with the browser closed if you like. It skips runs more than 30 seconds late instead of replaying them after downtime. Routines target an existing agent session and skip agents that report working or blocked. They do not start a replacement agent. Use **Pause**, **Resume**, **Edit**, or **Archive** to manage the schedule; archived run history stays readable. **Test now** sends the instructions once without changing the schedule, even while paused.

An agent can propose a routine with `swarmhub-herdr propose-routine < routine.json` from its own session. The JSON contains `name`, `task`, and a supported `schedule`, for example:

```json
{"name":"Morning review","task":"Summarize the project notes.","schedule":{"kind":"daily","hour":9,"minute":15,"weekdays":true,"timezone":"Europe/Warsaw"}}
```

In the agent’s conversation, choose **Review proposed routine** to edit the schedule or instructions. You can review or dismiss a proposal while Herdr Core is offline. To save it, choose the originating running session or a running session on the same agent profile. The routine is saved paused with no run history or upcoming run. Resume it to schedule automatic runs.

Run history separates delivery from the outcome. When the agent uses the supplied `routine-result` command, it can report that specific run as **Succeeded** or **Failed** and include a written summary. **View result** opens the saved report in the conversation, including when Herdr Core is offline. If the agent doesn’t report an outcome, SwarmHub keeps the delivery record and does not infer whether it succeeded. The command works once for the receiving session and uses that runtime’s normal tool permissions.

To trigger a routine from another process on the workspace host, select **On webhook** instead of a time schedule. Save the routine and choose **Generate key**. SwarmHub shows the key once; **Rotate key** replaces it. POST to the displayed address with `Authorization: Bearer <key>` and a unique `Idempotency-Key` header. You can send an empty body or a JSON object of up to 3 KiB. The agent receives that object as input data alongside the routine’s own instructions. Webhooks use the bridge’s loopback listener; they do not make the workspace public.

To narrow a trigger, add up to four conditions under **Only run when these conditions match**. Use a dot to find nested fields, such as `repository.full_name`, and enter a case-sensitive text value. For example, require both `repository.full_name` to equal `example/docs` and `action` to equal `opened`. All conditions must match. An authenticated event that doesn’t match receives HTTP 200 with `{"ignored":true,"reason":"filter_mismatch"}`; it doesn’t start a run or use its idempotency key. **Test now** still runs the saved instructions once without a webhook event.

Turn on **Review matching events before running** for any webhook routine to hold matching events in **Events awaiting review**. Open an entry to see the data the agent would receive, then choose **Approve and run** or **Dismiss**. Approval requires an active routine and an available agent. If the routine changed while an event waited, dismiss that event; it cannot run under the changed settings. Waiting events survive a restart, with a maximum of 20 per routine. SwarmHub clears the stored payload when you approve or dismiss an event, or archive its routine. For generic and GitHub webhooks, an HTTP 202 response with `awaiting_review: true` confirms receipt without starting a run.

For a GitHub repository webhook, choose **On GitHub issue or pull request** and use the generated key as the [GitHub webhook secret](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries). The displayed address is a local receiver. A relay on the workspace host must forward the original JSON bytes and `X-Hub-Signature-256`, `X-GitHub-Event`, and `X-GitHub-Delivery` headers to that address. No relay or public endpoint is created by SwarmHub. Set the GitHub content type to `application/json`.

GitHub deliveries can be up to 512 KiB. Routine conditions can match the event type (`event`), `action`, or `repository.full_name`. The agent receives those fields and the issue or pull request number and title; the full body and sender details are left out. Exact replays are deduplicated by the signed body. Rotating the key or changing the workspace access token requires updating the GitHub secret. After changing the workspace token, choose **Rotate key** to get the new secret.

For Slack, set `SWARMHUB_SLACK_SIGNING_SECRET` to your app’s signing secret on the workspace host. Subscribe the app to Slack’s [`app_mention` event](https://docs.slack.dev/reference/events/app_mention/). The app’s Events API Request URL must use a relay that forwards the raw JSON and Slack signature and timestamp headers to the workspace’s local `/hooks/slack` receiver. One receiver serves all Slack routines and responds to Slack’s URL verification challenge.

To manage the Slack signing secret in **Vault**, configure `SWARMHUB_SLACK_VAULT_ENTRY` instead of `SWARMHUB_SLACK_SIGNING_SECRET`. Add the named value under **Vault → Connections waiting for a secret**. The next delivery uses the saved value; you can replace it without restarting the bridge. Vault also lists which connection uses each saved name.

Choose **On Slack app mention** and enter the workspace ID as `team_id` and the channel ID as `channel`. Only matching mentions can run the routine. SwarmHub checks the [Slack signature and timestamp](https://docs.slack.dev/authentication/verifying-requests-from-slack/) and deduplicates the signed event ID for each routine. It passes the workspace, channel, and up to 400 characters of mention text as input data. It does not install a Slack app, expose a public URL, or post back to Slack.

When you start a replacement session for a saved agent, open that agent’s **Routines** and choose **Move to current session** on a routine tied to an older session. The routine keeps its instructions, schedule, webhook key, and run history. Moving pauses it; review the replacement session and choose **Resume** when it should run again. Past runs still link to the session that received them.

An HTTP 202 means the event was accepted for delivery. Retrying an accepted event with the same idempotency key returns the original run instead of starting another. A paused routine rejects new events, and the endpoint accepts up to 10 new events per routine per minute. Use **Run history** to check delivery and outcome; accepted work is not replayed automatically after a restart.

## Reuse a skill

Open **Skills** to save a procedure, or choose **Save as skill** on an agent reply and edit the proposed instructions before saving. Use **Manage skills** in an agent’s details to hide or restore a skill in that session’s picker. The private library is shared across agents.

Use **Import skill file** to review a Markdown or plain-text file before saving it as a new skill. The heading or filename suggests a name. **Download skill copy** saves a JSON file containing the skill’s name, description, and instructions. Importing this copy creates a separate skill; it does not overwrite the original or carry across settings such as agent availability. Imports contain instructions only, with a 10 KiB limit. Supporting files and scripts aren’t installed.

From an agent’s composer or a routine editor, choose **Use skill** to preview the instructions, then **Add to draft**. This copies the reviewed text and version into the draft. It doesn’t send anything or change permissions. Later edits to the library do not silently change a draft or saved routine. Archiving a skill removes it from pickers and keeps past uses unchanged.

An agent can propose a reusable skill with `swarmhub-herdr propose-skill < skill.json`, using the workspace binary from its own session. The JSON contains `name`, `summary`, and `instructions`. The conversation offers **Review proposed skill**; you can edit and save it to the Library or dismiss it. A proposal alone creates no skill and runs no commands. Reviewing saved proposals works while Herdr Core is offline.

## Manage the server’s skillshare skills

[skillshare](https://skillshare.runkids.cc) is a separate command-line program. It keeps one folder of agent skills, the source, and links it into each agent program’s own skills folder, a Target. If it is installed on the server, an app can show its skills and Targets and turn skills on and off through the workspace. This has nothing to do with the workspace’s own Skills library in [Reuse a skill](#reuse-a-skill).

The workspace runs the `skillshare` program it finds on its `PATH`. Set `SWARMHUB_SKILLSHARE` to the program’s full path to use another one. Without the program, every route below answers with `installed: false` and a `problem` that says so. The workspace keeps no copy of skillshare’s state: each answer is what skillshare reports at that moment.

- Turning a skill on or off changes the source only. The agent programs see the change after the next sync.
- A sync links the enabled skills into every Target and removes the links of disabled ones. A skill folder of your own that is already in a Target stays as it is, also when it has the name of a skill in the source: the workspace never asks skillshare to overwrite.
- Adding a Target only writes skillshare’s configuration. Nothing is linked into that agent program’s folder until the next sync, and from then on that program loads every enabled skill, in every session of the server account, including the ones you start yourself.
- The workspace does not install, update or remove skills. Use `skillshare` on the server for that.

### For apps

Every route needs the access token. A `GET` always answers 200; read `problem` (`null` when all is well) to learn why something is missing.

- `GET /api/skillshare` returns `installed`, `version`, `problem`, `source` (the folder), `skill_count`, `skills` and `targets`. Each skill has `name`, `path` (its folder in the source), `description` (the first 300 characters from its `SKILL.md`, or `null`), `enabled`, `origin` (`local`, `tracked`, or where it was installed from, such as `github`) and `source` (the place it was installed from or its tracked checkout, or `null`). Each Target has `name`, `path`, `mode`, `status`, `linked` (skills in its folder now) and `skills_enabled`. An answer carries at most 500 skills; `skill_count` counts them all.
- `POST /api/skillshare/enable` and `POST /api/skillshare/disable` take `{"name": "…"}`, a name from that list. They answer like the `GET`, plus `changed` (the skills whose state changed) and `output` (what skillshare said; empty when the skill already was as asked).
- `POST /api/skillshare/sync` runs a sync. With `{"dry_run": true}` it changes nothing and reports what a sync would do. It returns `dry_run`, `linked`, `local`, `updated`, `pruned`, `ignored`, the same numbers for each Target in `details`, and `targets` as they are afterwards.
- `GET /api/skillshare/targets` returns `installed`, `version`, `problem` and `targets`.
- `GET /api/skillshare/targets/addable` returns `installed`, `problem` and `agents`: the names of the agent programs skillshare finds on the server and does not link into yet, such as `claude`. skillshare offers a program once that program’s own folder exists. To answer, the workspace runs `skillshare init --discover --dry-run`, which writes nothing but a line in skillshare’s own log.
- `POST /api/skillshare/targets` takes `{"agent": "…"}`, a name from that list, and makes it a Target with `skillshare init --discover --select`. It answers like `GET /api/skillshare/targets`, plus `added` and `output`.

A refused `POST` answers with an `error` to show as it is:

| Status | Meaning |
| --- | --- |
| 404 | skillshare lists no skill with this name. |
| 409 | The agent program is already a Target, skillshare lists two skills with this name, or skillshare ran and the skill is still as it was. |
| 422 | The body is not the expected one, skillshare does not offer this agent program, or the skill’s folder name has characters skillshare would read as a pattern. |
| 502 | skillshare failed or is not set up. The `error` carries what it said. |
| 503 | skillshare is not installed. |
| 504 | skillshare took too long and was stopped: 20 seconds to read, 60 to change, 120 to sync. |

The workspace passes skillshare only a skill folder or an agent program name that skillshare itself just listed, as one argument and without a shell. Changes run one at a time and finish even if the app disconnects.

## Capture Claude Code replies

Install and sign in to Claude Code normally under the account running Herdr. Open it once in the intended working directory to handle interactive setup and trust prompts. Add a Herdr template such as `claude.md`, replacing the path with the installed workspace binary:

```markdown
---
description: Claude Code with saved replies
command: /absolute/path/to/swarmhub-herdr run-claude
---
```

Choose that template when creating an agent. To choose a model, add Claude’s normal `--model` option to that template command, or use a separate template per model. Do not name the file `claude.md` or `codex.md`: Herdr resolves a template name before a program, so `hc run claude` would start the template instead of Claude Code.

Leave out `ready: quiet` for Claude Code and Codex. Both report their status to Herdr, and Core waits for that report before it sends the first task. With quiet readiness, a real Claude Code 2.1 launch received the first task as typed text without submitting it.

`run-claude` starts the locally installed Claude Code in the terminal and adds a session-scoped [Stop hook](https://code.claude.com/docs/en/hooks#stop). It also adds tool hooks that report each tool call's name and one line about it (the command, file, search, or address) to the running workspace. That activity is kept in memory only, never decides whether a tool may run, and is skipped when the workspace is stopped. It records the reply delivered by the hook (up to 128 KiB) as a message, including for turns entered in the terminal. It does not read provider transcript files, change permissions, or handle credentials. Replies from subagents are not added automatically. Use Claude’s regular configuration files for additional settings; the wrapper uses `--settings` for the hook. Hooks disabled by managed settings, or versions which do not return the reply text, fall back to the live terminal view.

Add `--workspace-preview` to a fresh interactive template to show a temporary reply preview in SwarmHub: `swarmhub-herdr run-claude --workspace-preview`. If using approvals, place `--workspace-approvals` first. Claude Code’s [MessageDisplay hook](https://code.claude.com/docs/en/hooks#messagedisplay) supplies completed lines from the bound launch’s assistant message. The preview is limited to 32 KiB, expires, and omits messages that arrive only as a final batch. The Stop hook still saves the final reply. Resumed sessions, explicit session IDs, print mode, and other specialized launches keep their existing behavior. SwarmHub does not open transcript files or forward reasoning, tool output, or credentials.

Other trusted agent adapters can pipe their reply text into `/absolute/path/to/swarmhub-herdr capture-reply` while running under a workspace-launched Herdr session. The launch supplies the private journal location and a session key. A reply can be recorded even while the browser service is stopped. This is an opt-in for agents running under the same OS account; it is not an isolation boundary between agents.

For a quoted follow-up, the prompt supplies an absolute `swarmhub-herdr thread-reply TOKEN` command when the session has a launch identity and the command fits in the task. An agent with tool access can pipe one plain-text answer of up to 128 KiB to the command. The link works once and only with the receiving launch identity; it doesn't change the runtime's tool approvals. The answer can be recorded while the workspace service is stopped, and appears with a quote linking back to the follow-up.

## Run Codex

Install Codex CLI and sign in normally under the account running Herdr. Add a template such as `codex.md`:

```markdown
---
description: Codex with saved replies
command: /absolute/path/to/swarmhub-herdr run-codex
---
```

The first launch stops at Codex’s **Hooks need review** prompt and holds the task until you answer. Open **Take over**, review the SwarmHub hooks, and trust them: `capture-codex-reply` on Stop saves the reply, and `tool-activity` on PreToolUse and PostToolUse reports which tool is running. Codex remembers that decision for the same installed path, so later launches start without the prompt. Use the same installed path between launches so the hook definition stays stable. Prepare workspace trust and sign-in before relying on quiet readiness. Select a model by adding Codex’s normal `--model` option to the template command, or keep the defaults supplied by your Codex config.

`run-codex` adds a session-only [Codex Stop hook](https://learn.chatgpt.com/docs/hooks#stop). It does not edit user or project hooks, bypass hook trust, change the sandbox, or handle credentials. The workspace records a reply once per Codex turn when a turn ID is present. A terminal remains available if the hook isn't trusted, doesn't run, or doesn't return text.

### The reply as Codex writes it

Codex has no hook for unfinished text. Its app server does send the text a message gains to every client of a conversation, and its terminal UI can run against an app server (`codex --remote`). A template command that ends in `run-codex`, with nothing after it but `--workspace-approvals`, therefore starts three processes in the terminal:

- A private Codex app server for this session, started with the same hook settings `run-codex` would otherwise give the terminal UI. Codex knows each hook by its text and position, so the hooks you trusted stay trusted and run as before.
- Codex's own terminal UI, connected to that server. Tasks, steering, the stop key, approvals and **Take over** go through it as before.
- `swarmhub-herdr codex-stream`, which joins the UI's conversation as a second client and passes the text of the message being written to the workspace. It only listens: it never answers a question the server asks, so the UI stays the one that decides.

The reply so far shows in the same place as Claude Code's and OpenCode's: `…/draft` and the event stream below, up to 32 KiB. It is the message Codex is writing now, so a short note before a tool call is replaced by the answer that follows, and it goes away when the turn ends or is stopped. The Stop hook still saves the final reply.

- The app server and the follower end with the terminal UI. Each session has its own; Codex's shared background server is not used or changed.
- A session takes one more Codex process than before. `run-codex` starts the terminal UI as soon as the app server listens.
- How long that takes depends on the server's disk, not on its processor ([How long a Codex start takes](#how-long-a-codex-start-takes)). `run-codex` waits up to 20 seconds, so that either way of starting fits in the 60 seconds Herdr Core holds a launch's first task for.
- Put `SWARMHUB_CODEX_STREAM_WAIT=30` (1 to 45 seconds) in front of the template command to change the wait.
- If the app server does not listen in that time, or ends first, `run-codex` starts Codex the old way and that session's replies appear whole.
- A template with other Codex arguments (a resumed session, a fixed sandbox) starts the old way too.
- Put `SWARMHUB_CODEX_STREAM=off` in front of the template command to always start the old way.
- A session that started the old way says why. While it runs, its agent carries `reply_arrives_whole` with the reason in `/api/workspace` and in the event stream's `snapshot` and `agent` events. The same sentence is in a file under `codex-stream/` next to the journal, kept for 30 days.
- Set `SWARMHUB_CODEX_STREAM_LOG` to an absolute file path to also record how long each start waited and what the follower and the app server wrote.

### How long a Codex start takes

Measured with Codex 0.169 on a server with a spinning disk that other jobs share:

| The server's disk | App server listens | Codex reports that it is ready | Conversation open |
| --- | --- | --- | --- |
| Idle, Codex's files in memory | 0.2 s | 1.0 s | 1.1 s |
| Busy, files partly in memory | 15 s | 22 s | 32 s |
| Busy, memory short | 89 s, or not within the 20 s wait | 90 to 240 s | later still |

The processor is not what a slow start waits for. Before its app server listens, Codex reads its whole state database (`state_5.sqlite`, 7 MB on that server) and about a thousand pages of its log database (`logs_2.sqlite`, 65 MB), one page at a time in the order SQLite asks for them. When the server is short of memory, those pages have been dropped since the last start, and on a busy disk each read takes a seek. A traced start spent 66 of its 89 seconds on 2,800 such reads.

`run-codex` therefore reads Codex's databases through once, in file order, while Codex starts: every `*.sqlite` and `*.sqlite-wal` file of up to 128 MB in `CODEX_SQLITE_HOME`, `CODEX_HOME` or `~/.codex`, smallest first, 256 MB in all, for 30 seconds at most. Read that way the same megabytes take a second or two, and nothing when they are still in memory: on copies of the two files on the same busy disk, the log database's thousand pages took 22 to 33 seconds in SQLite's order, and the whole file 1 to 3 seconds in file order. It only reads: the files are opened read-only and without changing their access time, and no lock is taken. Put `SWARMHUB_CODEX_PREFETCH=off` in front of the template command to leave them alone.

What it can't shorten: Codex's own program file (280 MB), which the server reads back from disk piece by piece when memory is short, and the first turn's connection to the model. Start the agent before the first message ([Start an agent before the first message](#start-an-agent-before-the-first-message)) so that nobody waits for either.

## Run OpenCode V2

Install the [OpenCode V2 CLI](https://opencode.ai/docs/cli/) under the account running Herdr. Configure the provider and model in [OpenCode](https://opencode.ai/docs/providers/); local endpoints and hosted providers use the same SwarmHub interface. Open the model in OpenCode once to finish any sign-in or setup prompts, then add a Herdr template such as `opencode.md`:

```yaml
---
description: OpenCode with saved replies
command: /absolute/path/to/swarmhub-herdr run-opencode mini --model provider/model
ready: quiet
stop: ctrl+c
---
```

Replace `provider/model` with a model available in OpenCode, or omit `--model` to use its configured default. `run-opencode` starts a private OpenCode server for that terminal and loads the bundled plugin. The conversation shows up to 32 KiB of live text while OpenCode replies. This preview is temporary; only the final text of successful top-level turns (up to 128 KiB) is saved and searchable. Tool output, reasoning, and replies from child sessions stay in OpenCode.

The plugin reports work, completion, errors, and pending permission requests or questions through Herdr's terminal status protocol. When the agent needs a decision, select **Open terminal** next to the composer to respond in OpenCode. Use **Take over** for startup prompts such as sign-in. Plain `opencode` templates, including V1, still work through the terminal and can use the generic `capture-reply` command.

To opt in to structured OpenCode delivery, use the literal command `/absolute/path/to/swarmhub-herdr run-opencode --api-first-task mini`. If using approvals, put `--workspace-approvals` before `--api-first-task`. Use OpenCode V2.3 and select the model in SwarmHub or configure its default in OpenCode. SwarmHub starts an authenticated loopback server, creates a session, and attaches Mini. It sends the first task, web follow-ups, group tasks, and routine tasks through [OpenCode’s session API](https://opencode.ai/docs/api) in that same session. Web sends need not wait for Mini’s composer; open the terminal for direct takeover. Pending questions or permission requests must be resolved before sending new work. Leave the Herdr template’s Markdown body empty and put instructions in the SwarmHub profile instead. This mode runs the verified command directly, so it skips the template body and template-only readiness and key overrides.

In a running API-backed OpenCode session, open **Details → Change OpenCode model** to read its current selection and the default reported by OpenCode. Apply an exact `provider/model` ID or restore the reported default. The latter applies that exact default ID at the time of the change. SwarmHub refuses a change during pending work or when the reviewed selection has changed, and reads back the confirmed selection from OpenCode. This affects subsequent tasks sent from SwarmHub. Mini’s displayed model may differ. Older API-backed sessions need a new launch to expose these controls; legacy terminal templates are unchanged.

Plain `run-opencode mini` keeps the existing Herdr template behavior. The Mini client [does not report when its composer is ready](https://github.com/anomalyco/opencode/issues/61191), so Herdr's quiet readiness can type the first task too early on a slow startup. If no reply appears, open the terminal. Submit the task there if it is still in the composer. Enter it again only after confirming it is missing from both the composer and the conversation. SwarmHub does not resend a task automatically when delivery is uncertain.

## Start an agent before the first message

An agent's program takes a while to start: on a busy server Claude Code needs 6 to 20 seconds and Codex longer. A launch with a task makes the person wait that long for the first answer. A client can start the agent when the person opens the chat instead, and send the first message to an agent that already runs.

`POST /api/agents` with `"warm": true` and no `task` starts the template's program and types nothing, so no model turn is spent:

```json
{"name": "jarvis-a79b16", "template": "swarmhub-codex", "warm": true, "profile_id": 12, "model_id": "gpt-6-astra"}
```

Every other field means what it means in a launch with a task (`profile_id`, `model_choice` or `model_id`, `standing_instructions`, `instructions_revision`, `collect_results`, `projects`, `expected_runtime`), and the launch is recorded the same way, so the session has its history, its event stream and its place in `/api/workspace` at once. The answer (status 201) comes as soon as the program runs, in about a second, and is the agent as a launch with a task answers it, with `first_message` left `null`.

The first message goes through `POST /api/agents/{address}/{created_ms}/messages` like any later one. It is saved as the session's first task, and replies, tool calls, helpers and files work as in a session that started with a task. What a launch with a task types around the task (the profile's standing instructions, the note about the results folder, the note about the agent's projects) is typed around the first task that reaches a warm agent, whether it comes as a message, a group task or a routine.

### Tell a starting agent from a ready one

Every agent in `/api/workspace`, in the answer to a launch, and in the event stream's `snapshot` and `agent` events carries:

| Field | Meaning |
| --- | --- |
| `ready` | `true` when a task sent now is typed at once. `false` only for a warm agent whose program has not reported its status yet, and for an agent that has ended. |
| `warm` | `true` from a warm launch until a task has reached the agent. |
| `warm_ends_ms` | Only while nothing was sent to a warm agent: when the workspace ends it for being idle. |

An agent is ready once its program has reported its status to Herdr Core for the first time, which is what Core waits for before it types a launch's first task. The event stream sends an `agent` event when `ready` or `warm` changes.

A message sent to a warm agent before it is ready is not lost and is not typed into a start-up prompt. The workspace saves it, answers at once with status 202 and `{"status": null, "started": null, "queued": true}`, and types it when the agent is ready. Its row is `pending` in the history until then and `sent` afterwards, and the event stream sends the row each time it changes. A message to an agent that is ready answers with status 200 as before, once it is typed.

- If the program has not reported 5 minutes after it started, the queued message is given up: its row turns `not_sent`, with a `detail` that says so. Nothing was typed. The program is probably showing a prompt: open its terminal. A later message is tried again and carries the instructions.
- Put `SWARMHUB_WARM_START_WAIT=600` (30 to 1800 seconds) in the bridge's environment to change that limit. It is generous because a start is slow exactly when the server's disk is busy: Codex has taken more than three minutes to report on such a server. Core gives a launch's first task 60 seconds.
- A group task or a routine for a warm agent that is not ready holds its caller instead, for at most 75 seconds after the agent's start. It is then refused with status 409 and `{"error": "…", "kind": "not_ready"}`.
- Warm starts suit programs that report their status when they start, such as Claude Code and Codex. A program that reports only once it works stays not ready, and its first message is given up after the limit; start it with a task.
- Codex reports a little before its conversation is open. A message typed in between waits in Codex's own composer and is submitted when the conversation opens, so nothing is lost, but the answer starts that much later.
- A template whose command gives OpenCode its first task (`--api-first-task`) can't be started warm. The request is refused with status 422.
- A template with a Markdown body still gets that body typed as its opening message once the program is ready, as Core does for every start from that template. That is a model turn, and the launch answers only after it was typed.

### An agent nobody writes to

A warm agent that gets no task is ended 30 minutes after it started. Put `SWARMHUB_WARM_IDLE_MINUTES` in the bridge's environment to change that; `0` keeps warm agents until someone ends them. The workspace looks once a minute.

An agent is only ended while all of this holds: no task was sent to it through the workspace (not even one whose delivery was never confirmed), no reply of it was saved, its program is not working or waiting for an answer, and it has finished at most the one turn that starting counts as for Codex. Together that covers text typed in its terminal. An agent that has had a task is never ended this way. A warm agent that was never written to leaves no conversation in the Library.

## Follow a session without polling

`GET /api/agents/{address}/{created_ms}/events` sends one running session as [Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html): everything a client needs to follow a turn, on one connection. It takes the same access token and `Host` as every `/api/` route, and no `Origin`. The polling routes stay as they are, and both read the same state, so a row has the same `id` and a tool call the same `seq` on either.

The first event is a `snapshot`. After it, an event is sent when something changes:

| Event | Data | Sent when |
| --- | --- | --- |
| `snapshot` | `core`, `address`, `created_ms`, `agent`, `history` (`items`, `before`), `draft`, `tools`, `helpers` | Once, first. |
| `history` | One saved row, as in `GET /api/history/{core}/{address}/{created_ms}` | A row is saved (a task, a reply, a file) or changes (a task goes from `pending` to `sent`). Replace the row with the same `id`. |
| `draft` | `{"id", "text"}`, or `null` | The reply so far starts, is replaced, or is gone. Replace what you have. |
| `draft_append` | `{"id", "offset", "text"}` | The reply so far gained `text`. `offset` is the length in UTF-8 bytes of the text you should already have. |
| `tool` | `{"seq", "tool", "detail", "finished", "failed"}` | A tool call starts, and again with the same `seq` when it ends. |
| `agent` | The agent as in `/api/workspace` | Its `state`, `status`, `ready` or `warm` changes ([Start an agent before the first message](#start-an-agent-before-the-first-message)). |
| `helpers` | The list as in `GET …/helpers` | A helper starts, answers, changes status or goes away. |
| `end` | `{"reason"}`: `ended` or `gone` | The agent's program has ended, or Core no longer has the terminal. The connection closes after it. |

A comment line (`: heartbeat`) is sent after 15 seconds without an event. A client that hears nothing for longer than that should reconnect.

To resume, add `?after=<id>` with the newest row `id` you have. The snapshot then holds only later rows, and the current `agent`, `draft`, `tools` and `helpers` in full. Without `after`, `history` is the newest page of 30 rows, and `before` is set when older rows exist; read those with the history route. With `after`, `before` is set only if more than 240 rows were saved in between.

- The stream sends differences from the current state, not a log. A slow reader gets fewer, larger updates, and a reader that takes nothing for 60 seconds is dropped.
- A reply row arrives before the `draft` it replaces is cleared.
- A row's later change (a task's delivery state, a reaction) is only sent for the newest 30 rows, and only while connected.
- At most 48 streams are open at once, over all agents. One more gets status 429.
- A session that already ended answers with its snapshot and `end`. A terminal Core no longer has answers 404.
- If a `draft_append` does not fit what you have (another `id`, or a different length), reconnect.

## Watch an agent’s desktop

To give an agent a graphical desktop on Linux, install Xvfb and x11vnc and configure its Herdr template with `command: /absolute/path/swarmhub-herdr run-desktop -- COMMAND [ARGS...]`. Each launch gets its own private X11 display. The workspace does not use the host’s desktop.

Choose **Details → Desktop** to watch. **Take over desktop** enables keyboard and pointer control, and **Return to watching** releases it. **Detach** closes the viewer and leaves the agent running.

While you have control, choose **Teach a task** and optionally describe the result you want to demonstrate. Choose **Start recording**, click through the task with a mouse, and choose **Stop recording**. The sample keeps up to 24 clicks over two minutes. It records mouse buttons and desktop positions only; it does not collect screen images, typed keys, clipboard data, or drags. Stop before signing in or handling secrets.

Label the steps and remove any clicks you don't want. **Review as skill** detaches from the desktop and opens an editable draft in the regular skill editor. Review the goal, labels, and instructions before choosing **Save skill**. Saving creates a text skill in your library: it does not replay the clicks, start the agent, or schedule a job. Returning to watch mode or detaching before opening the skill editor discards the sample.

## See what needs attention

The **Needs attention** badge collects pending approvals, blocked terminals, unanswered group questions and forms, and webhook events awaiting review. Open a row to go straight to the relevant review, terminal, or answer. Webhook events stay visible while Herdr Core is offline and can be dismissed there. If desktop notifications are enabled, new reviews can trigger a generic alert without exposing the event payload.

**Activity** collects saved replies, new Pages, and published files. Unread counts appear on the inbox and beside agents and groups in the roster. Open an activity item to mark it read and jump to the exact message, or use **Unread only** and **Mark all as read**. Viewing the latest messages in a focused conversation marks activity through the latest item shown as read. Read state survives restart and works while Herdr Core is offline.

In **Activity → Desktop notifications**, opt in to browser alerts for new results, pending approvals, and group questions or forms. The browser may ask permission. Keep a signed-in workspace tab open; alerts can arrive when the tab is in the background, subject to the browser and operating system. Alerts omit names, message text, and approval details. Click one to open the saved result or the relevant inbox. To mute a particular agent’s results and approvals, clear **Desktop notifications for this agent** in **Details**. That setting is local to the browser and leaves the agent’s unread count intact. Mobile push and alerts for a closed workspace are not supported.

## Review permission requests

To review Claude Code or Codex requests from the browser, add `--workspace-approvals` immediately after `run-claude` or `run-codex` in the agent template, before any regular agent flags. This adds a session-scoped PermissionRequest hook ([Claude Code](https://code.claude.com/docs/en/hooks#permissionrequest), [Codex](https://learn.chatgpt.com/docs/hooks#permissionrequest)). For Codex, review and trust the additional hook in `/hooks`; the inbox supports Bash and `apply_patch` requests that include reviewable commands. Open **Approvals** to inspect the exact arguments and choose **Allow once**, **Deny**, or **Use terminal**.

For OpenCode V2, use `run-opencode --workspace-approvals mini`. The inbox shows the action and resources for pending `read`, `glob`, and `grep` requests. Other actions and questions stay in the terminal. **Allow once** applies to this request; **Deny** uses OpenCode's [native rejection](https://opencode.ai/docs/permissions/#approvals), which can also reject other pending requests in the same session. **Use terminal** leaves the native prompt available. SwarmHub records approvals and denials only after OpenCode acknowledges the decision.

For a `read` of one regular file inside the agent’s working folder, the inbox can also offer **Allow matching reads for 1 hour**. SwarmHub remembers that session and path only after OpenCode confirms the decision, then checks the file’s identity and metadata before approving future requests. Use this in a trusted working folder: OpenCode still opens the path itself after approval. Other files, aliases, directory or pattern searches, and other tools still need their usual review. The rule disappears on workspace restart. Revoke it anytime under **Temporary read rules**; confirmed uses remain in Recent decisions as **Allowed by read rule**.

There are no automatic approvals or saved permission rules. The agent still enforces its own configuration. If the bridge is unavailable, the hook is canceled, or no choice is made within 45 seconds, the hook returns no decision and leaves the normal provider flow in place. Interactive forms and prompts the installed agent does not expose through this hook remain in the terminal. Decision history stores the agent name, provider, tool, times, and decision sent. Tool arguments are kept in memory only while a request is pending.

## Verify

```sh
cargo fmt --check
cargo clippy --locked -- -D warnings
cargo build --locked
python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr"
python3 tests/preview_smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify the private X11 display and desktop takeover (Linux, Xvfb, x11vnc, and xdpyinfo):
python3 tests/desktop_smoke.py "$PWD/target/debug/swarmhub-herdr"
# Verify teaching against Chrome and a real isolated X11 desktop (Linux, Xvfb and x11vnc):
SWARMHUB_TEST_FOCUS=desktop-teaching python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Optional interactive browser coverage requires Chrome and Node.js 22+:
python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify browser installability, mobile layout, and the offline boundary in Chrome:
SWARMHUB_TEST_FOCUS=pwa python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify Appearance contrast, keyboard navigation, viewport, reload, and System theme changes:
SWARMHUB_TEST_FOCUS=appearance python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify agent template export and offline import; omit Chrome for API checks only:
node tests/portable-profiles.mjs "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify Codex hook discovery with the real CLI, then run the Codex-focused fixture:
python3 tests/codex_discovery.py "$PWD/target/debug/swarmhub-herdr" "$(command -v codex)"
SWARMHUB_TEST_FOCUS=codex python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# In a network namespace with only loopback enabled, verify interactive Claude Code:
python3 tests/claude_preview.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v claude)"
# Verify OpenCode V2 through Herdr using a local mock model endpoint:
SWARMHUB_TEST_FOCUS=opencode SWARMHUB_TEST_OPENCODE_BIN="$(command -v opencode)" python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify OpenCode's permission prompt and the browser terminal handoff:
SWARMHUB_TEST_FOCUS=opencode-status SWARMHUB_TEST_OPENCODE_BIN="$(command -v opencode)" python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Verify the OpenCode approval inbox and its terminal fallback:
SWARMHUB_TEST_FOCUS=opencode-approvals SWARMHUB_TEST_OPENCODE_BIN="$(command -v opencode)" python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=read-approval-rules python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Optional: isolate Skills, group, or profile checks
SWARMHUB_TEST_FOCUS=skills python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=groups python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=group-files python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=group-results python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=group-questions python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=group-forms python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=group-handoffs python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=pages python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=page-tasks python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=page-share python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=page-html-export python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=search python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Media smoke uses FFmpeg with libx264/libvpx to generate short test recordings.
SWARMHUB_TEST_FOCUS=media python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Record through Chrome’s synthetic microphone and verify direct and group voice memos.
SWARMHUB_TEST_FOCUS=voice-memos python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# Report native on-device availability, then exercise dictation with an injected recognizer; no pack is installed.
SWARMHUB_TEST_FOCUS=dictation python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
# PDF smoke uses Python ReportLab to generate plain and password-protected documents.
SWARMHUB_TEST_FOCUS=pdf python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=results-auto python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=storage-contention python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr"
SWARMHUB_TEST_FOCUS=profiles python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=profile-create python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=skill-proposals python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=routine-proposals python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=memory-proposals python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=email-drafts python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
## GitHub fixture only: use a separate test binary with the opt-in github-test-fixture Cargo feature.
SWARMHUB_TEST_FOCUS=github-project python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=github-access python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=profile-copy python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=profile-avatar python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=grok-import python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=grok-skill-import python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=grok-export-helper python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=connected-files python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=agent-drive-ui python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=roster-sections python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=runtimes python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=runtime-setup python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
SWARMHUB_TEST_FOCUS=instructions python3 tests/smoke.py "$(command -v hc)" "$PWD/target/debug/swarmhub-herdr" "$(command -v google-chrome)"
```

The smoke uses scratch XDG directories, a model-free terminal fixture, and stand-ins for agent CLIs that call the actual hook helpers. It verifies persisted history, files, groups, routines, terminal takeover, and permission review, including fallback when the bridge stops. It stops the scratch Core on exit and makes no provider requests.

The [desktop smoke](tests/desktop_smoke.py) creates a scratch X11 display and checks that a missing authorization cookie is rejected, a watcher cannot move the pointer, and the display is removed when the agent exits.

The [feature plan](../docs/herdr-workspace.md) maps the remaining interface work to the published Grok Bot workflows.
