# iPhone design notes

The rules the [screen drawings](screens.html) follow. Taken from the earlier iPhone specification of 14 October 2026; the parts about that app's server were left out. The [screen map](screen-map.md) lists every drawing.

The drawings use the sample agents Atlas, Mira, Patch and Scout. Their controls only change the local preview.

## Navigation and interaction

Chats is the landing tab. A prominent search field and a plus menu sit above the list. The list stays useful with one agent or dozens; there is no dashboard ahead of the conversations. A row opens a full-screen chat. The tab bar is hidden while reading a conversation, so the bottom of the screen belongs to the composer.

The chat header shows Back, the agent or group, and an overflow menu. Tapping the name opens the agent's details (the Mac app's side panel becomes a full-screen destination on iPhone). Deeper lists use native push navigation. Editing, attachments and model choices use sheets where a short choice returns straight to the chat. Large text editors use full-screen destinations.

Settings opens as one short page; technical choices sit under Advanced. A control that cannot work says why instead of pretending to succeed.

An action that the server must confirm shows as pending until it is confirmed. A tap never implies that it worked.

## Design system

Use the system font and SF Symbols in a native app. The drawings use original vector symbols and geometric marks. Native bot avatars can reuse the vendored BotAvatarsKit (MIT) after its iOS build is checked, keeping its licence credit.

| Element | Direction |
| --- | --- |
| Canvas | Dark chat `#141416`, panel `#19191C`, raised `#232327`; light counterparts follow the Mac app's `AppColor` |
| Primary action | Neutral graphite; agent colours identify agents rather than colouring every control |
| Typography | System text styles; about 34 pt large titles, 17 pt body, 15 pt secondary, 13 pt captions at the default size |
| Spacing | 4 pt rhythm, 20 pt horizontal content inset, interactive targets of at least 44 pt |
| Conversation | Plain assistant paragraphs, restrained user bubbles, secondary timestamps, composer above the keyboard and safe area |
| Rows | Marks about 40 pt, compact name and preview, quiet separators and unread indicators |
| Sheets | Opaque grouped surfaces, clear Cancel and Done, full screen for large text and accessibility sizes |
| Motion | Native navigation plus the avatar states; pause when inactive, honour Reduce Motion and avatars switched off |
| Accessibility | Dynamic Type reflow, VoiceOver names and statuses, visible focus, labelled icon controls; colour always paired with text |
| iPad | Later: adaptive split navigation that keeps the iPhone flows; do not assume three desktop columns on a phone |

## Things a phone app must respect

- The agent runs on the server. iOS may suspend the app; a connection held open or a timer is not a way to deliver results while the app is closed. On returning to the foreground, read the server's state again.
- Keys live in the Keychain and are saved only after a connection has been confirmed. An iPhone's `localhost` is the phone, not the user's Mac or server.
- Never cut text off silently. If something is too large to send, say so.
