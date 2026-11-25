# Changes since SwarmHub 0.8.16

- See a bot’s role in its chat header and open its model settings from a labeled button. The chat, sidebar and Details panel use the dark and light colors shown in the website preview.
- Open **Details → Team** or press ⌘2 to follow open handoffs, review recent exchanges and find scheduled CI watches. Details reopens immediately after closing, including when you switch bots.
- Open **Activity** in the sidebar to find chats that need attention, see work in progress, and jump to unread answers. Press ⇧⌘A with the sidebar hidden. Inspect an approval there and use ⌘Return to allow it once or ⌘Delete to deny. Your current chat stays open.
- Reopen a long chat at your saved reading position or jump straight to the latest message. Reply drafts stay with the bot or group where you wrote them.
- Send a follow-up while a bot starts. Codex can use it in the current answer, including when the bot is loading your earlier chat. For a workspace without live steering, it stays queued as the next message.
- Click the model in the chat header to open that bot’s settings. When you change providers, the next message carries the conversation forward. The header shows the session’s reported model and any pending change. When a provider leaves its model unspecified, the header names the active provider.
- See what a coding helper is working on and read its result in the parent chat. The parent can save a next step to run when the helper finishes, leaving the chat available for other messages. Automatic continuation requires workspace 0.2.14.
- Open **Manage AIs on this Mac** beside a bot’s AI choices. **Scan again** checks installed programs and refreshes the open picker. Antigravity appears by name alongside Gemini. Discovery skips Codex’s interactive update flow.
- Settings now recognizes OpenCode installed as `opencode2`, including alongside an older `opencode`. If the bot’s model list fails to load, its Model panel explains why and offers **Reload models**.
- If the workspace connection drops while a bot runs a command, the chat can reconnect and retrieve its answer without submitting the command again. If Stop fails while disconnected, the chat shows that the bot may still be running and checks for its final answer after reconnection. Activity and Search remain available from the keyboard.
- In the updated workspace on iPhone, tap **Review** in a chat to open pending requests. The header clears the status bar and the composer clears the home indicator.
- Reopen previously viewed images and videos while the workspace is offline, including after restarting SwarmHub.
- Review an available update or reopen the sidebar from an empty workspace with the sidebar hidden.
