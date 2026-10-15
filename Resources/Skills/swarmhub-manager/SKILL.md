---
name: swarmhub-manager
description: "Use when Konrad asks to create, change or retire bots (Hermes profiles), to read or change their instructions, avatars or descriptions, to change bots' models, to list or connect the bots already on the box, or to install, log in to or out of the coding tools (Claude Code, Codex CLI) and ChatGPT accounts, to report bots' models and sub-agent models, or to check this box's capacity or set its coding job limit. Installed by SwarmHub, v{{VERSION}}."
version: 1.2.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub bot manager

{{MANAGER_TEXT}}

When asked to list every bot, connect bots made before SwarmHub or restore a connected bot's old key, first read `{{SKILL_DIR}}/references/box.md` (`cat` it).
When asked to install the coding tools, log in or out, or check the accounts, first read `{{SKILL_DIR}}/references/accounts.md` (`cat` it).
When asked which models the bots or their sub-agents use, first read `{{SKILL_DIR}}/references/models.md` (`cat` it).
When asked about this box's capacity or to set its coding job limit, first read `{{SKILL_DIR}}/references/capacity.md` (`cat` it).
