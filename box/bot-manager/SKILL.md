---
name: bot-manager
description: "Use when Konrad asks to create a new bot (sub-agent), list his bots, read or change a bot's instructions (its SOUL), change a bot's description or avatar, or retire a bot. Jarvis only."
version: 1.0.0
author: SwarmHub (P22)
license: MIT
metadata:
  hermes:
    tags: [bots, subagents, profiles, instructions, soul, avatar, swarmhub]
---

# Bot manager

You (Jarvis) manage Konrad's other bots on this box. Each bot is a Hermes profile with its own
instructions (`SOUL.md`), its own key and its own memory. SwarmHub, Konrad's Mac app, shows them.

All changes go through one helper. Run it in the terminal exactly like this (always `-B`):

    BOTCTL="python3 -B /home/hermes/.hermes/profiles/grok-jarvis/skills/agent-operations/bot-manager/botctl.py"

| Konrad wants | Command |
|---|---|
| see the bots | `$BOTCTL list` (add `--all` to include retired ones) |
| read a bot's instructions | `$BOTCTL show NAME` |
| a new bot | `$BOTCTL create NAME --description "ONE SENTENCE" --soul-file FILE [--shape S --colour C]` |
| change instructions | `$BOTCTL set-soul NAME --file FILE --dry-run`, then without `--dry-run` |
| change the description | `$BOTCTL describe NAME --description "ONE SENTENCE"` |
| change a bot's avatar | `$BOTCTL avatar NAME --shape S --colour C` (any bot, also you) |
| retire a bot | `$BOTCTL retire NAME` (moved aside and kept, never deleted) |
| SwarmHub lost a new bot's key | `$BOTCTL reissue-key NAME` (only bots you created) |

## Always ask first

Before `create`, `set-soul` (the real write), `describe`, `avatar`, `retire` or `reissue-key`, tell Konrad in
one short message exactly what you will do and wait for his yes. For instructions, show the
`--dry-run` diff (or the full new text for a new bot) and ask "Write this?". Reading (`list`,
`show`) needs no confirmation.

## Creating a bot

1. From Konrad's words pick a short lowercase name (`sales-helper`, `travel`), a one-sentence
   description, and draft the instructions.
2. Save the draft to `/home/hermes/.hermes/profiles/grok-jarvis/workspace/bot-drafts/NAME.md`
   (never a file named `soul.md`). Show it to Konrad, confirm, then run `create`. If the draft file
   already holds the confirmed text, don't write it again; to change it, read it first (the file
   tool refuses to overwrite a file it has not read).
   Suggest an avatar that fits the bot (see below) and include it in the confirmation.
3. The new bot copies your tools and settings but starts with empty memories, its own key and
   without this skill. Tell Konrad: "Open SwarmHub; it will offer NAME under new bots from Jarvis."
   New bots are reachable from SwarmHub, not from Telegram.

## Avatars

A SwarmHub avatar is one shape and one colour, nothing else (no images, no emoji):

- shapes: blob pebble bean egg squircle tablet capsule cylinder hex gem crystal wedge shield dome
  arch cloud teardrop leaf square sparkle clover flower heart house star
- colours: black brown red orange yellow green cyan blue violet magenta gray

If Konrad asks for something not on the lists ("a pink triangle"), offer the closest pair
(`magenta`, `wedge`) and ask. SwarmHub shows the change on its next refresh.

Good instructions are short: who the bot is, what it does for Konrad, its tone and language, and
what it must not do. Write them in the language Konrad uses for that bot.

## Never

- Never show, read aloud, copy or paste any key or any `.env` file. The helper creates keys and
  SwarmHub collects them itself; if asked for a key, say SwarmHub picks it up automatically.
- Never change the instructions of `default` or `grok-jarvis` (yourself); your own instructions are
  Konrad's to change in SwarmHub.
- Never edit a bot's `config.yaml` (model, provider) or delete a bot folder. Retire instead.
- Never run Python without `-B`, and never run Python from `/opt/hermes-core`.
- If the helper prints `botctl: ...`, tell Konrad what it said in plain words; don't work around it.
