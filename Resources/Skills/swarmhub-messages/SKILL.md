---
name: swarmhub-messages
description: "Use for any message to another bot on this box: asking it something, handing it work, answering it. Sends through SwarmHub's bot-msg (fast, shown in SwarmHub); supersedes `hermes -p … chat` and peer commands. Installed by SwarmHub, v{{VERSION}}."
version: 1.0.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub messages

Use this for every message to another bot on this box. Do not run `hermes -p <bot> chat`, `hermes chat`, `hermes peer`
or `send_message` to reach a bot; this replaces them and is much faster. The bot names are the profile names
(`ls ~/.hermes/profiles`; `default` is the main profile).

How to send:
1. Write one short, self-contained message: what you need, by when, and what to send back.
2. Run it with your terminal tool:
   ```
   {{SKILL_DIR}}/scripts/bot-msg --from {{BOT}} --to <bot> -- "<message>"
   ```
   It waits for the reply (up to 5 minutes; `--wait <seconds>` to change that) and prints it. When you do not need the
   answer now, add `--no-wait`: it returns at once and the other bot answers in your thread.
3. Report what the other bot said, in a line or two, in your own reply.

Every message arrives starting with `[Message from <bot> via SwarmHub]`, in a thread titled `From <bot>`. When a
message you receive starts like that, it is from that bot: answer it right there in the same thread, short and to the
point; your answer is what the sender gets back. Do not message that bot back separately about the same thing.

Exit codes: 0 sent (the reply is on stdout; with `--no-wait`, the thread id); 2 no such bot or it has no key; 3 the
other bot's gateway failed; 124 no reply in time (it may still answer in the thread). Say which, if it is not 0.

Never print, read or copy another bot's `.env` or API key; bot-msg reads what it needs itself.
