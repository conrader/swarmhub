Next pass on AgentApp (read the code, README and docs first; the teardown notes are in docs/ if present). Konrad's direction: the app should COPY the Grok Bot desktop app's look and be FEATURE-IDENTICAL, but implemented with our own code and our own original assets (no extracted Grok Bot images, icons, fonts or prompt text).

Layout (three columns like Grok Bot):
1. Left sidebar: the bot list (round avatar, name, unread dot), section groups, "+" new bot, hidden chats, account and settings at the bottom.
2. Centre chat: plain assistant text, user bubbles on the right, threaded replies, reactions (tapbacks), inline cards (question widget with options, draft email/message card with Send, approval card, attachment/image, link pills), one composer with attach and send, and a voice memo playback bubble.
3. Right side panel, OPEN by default, collapsible (Cmd+Shift+I), with tabs: Overview (bot name, title, description, avatar, memory summary, skills list), Routines (list, enable/pause, schedule/trigger, last run, create/edit), Media (grid of files and images from the chat), Computer (live noVNC view of the bot's desktop, with a take-over control), Members.
Also: a Settings window with sections (Account, Appearance/theme/accent, Notifications, Computers, Auto-review, Usage, Updates), a Cmd-K switcher, notifications for new messages, and per-bot settings (hide from sidebar, notifications).

Bot faces: replace the clay avatars with a set of 12 ORIGINAL flat, minimal, friendly bot-face icons in the spirit of Grok Bot's avatars (simple geometric head shapes in soft solid colours, two dot eyes and a small mouth, consistent style), drawn as SwiftUI Shapes/Canvas or generated SVG to PNG in Resources/Avatars. Keep the clay set selectable as an alternative.

Wire features to the existing Hermes/OpenClaw backends where possible; otherwise use clean stubs with mock data, clearly marked TODO. No animations beyond standard system ones.
Build with ./scripts/build.sh. Update the README with a feature-parity checklist (done / stubbed). Don't commit. Print a summary.
