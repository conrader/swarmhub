Follow-up pass on this repo (AgentApp SwiftUI prototype; read the code first). Konrad wants the look SIMPLIFIED to match the Grok Bot desktop app's look and feel as closely as possible, while using only our own code and assets (don't copy Grok Bot's icons, images, logos or text strings verbatim). NO animations: remove avatar animation and decorative motion; keep only standard system transitions.

Target look (minimal, calm, native macOS):
- Two-pane by default: a narrow left sidebar plus the chat. No right pane unless toggled (clicking the bot name in the chat header or Cmd+Shift+I opens a slim info pane; close with an X). Remove the always-visible sub-agents panel, tabs and extra toolbars.
- Sidebar: plain list of bots, each row = round avatar (about 28 pt), bot name, and an optional unread dot. No snippets, no search field, no section chrome by default. A small "+" (new bot) at the top. Account button at the bottom-left (avatar plus name) that opens Settings. Subtle selection highlight; uses the system sidebar material.
- Chat: no bubbles for assistant messages (plain text, comfortable line height, max width about 720 pt, centred); user messages in a soft rounded light-grey bubble on the right. Minimal header: avatar plus bot name only. Cards (approval, draft email, choice widget) as simple rounded bordered blocks with one primary button.
- Composer: one rounded field at the bottom with a placeholder, attach "+" on the left and a send arrow on the right. Nothing else.
- Typography: SF Pro system sizes (body 13-14 pt), generous whitespace, hairline separators, follows system light/dark, single neutral accent.
- Avatars: use the static clay PNGs in ./Resources/Avatars/ (robot, blob, bubble, headphones, fox, planet, coffee, octopus, pebble), bundled as SwiftPM resources; mock bots use them; the bot editor lets you pick one. Static only.
- Settings window: simple tabs General / Computer / Updates with few rows.
Delete unused views and code paths; keep the backends, persistence, approvals and the noVNC view (only inside the info pane preview and a full-screen sheet).
Rebuild with ./scripts/build.sh, and keep memory and launch time measurements in the README. Don't commit (the .git is read-only for you). Print a summary of what was removed, what changed, the build result, and the measurements.
