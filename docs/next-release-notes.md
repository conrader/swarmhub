# Changes since SwarmHub 0.8.23

- **Auto mode is on by default.** A bot works in its sandbox and automatic review answers its requests for wider access, so it no longer stops to ask you. Updating the workspace turns Auto on once for every existing bot, except bots set to ask before every tool call and read-only document reviewers. Turn it off for one bot in **Details → Approvals**; that choice is kept.
- Moving bots to another server keeps each bot's Auto mode. Before, a move left every moved bot in Standard mode on the new server, and their next sessions asked for permission in a read-only sandbox.
- The main bot now looks into a workspace problem itself when looking only reads (a terminal prompt, a status, a log) and reports what it found with a recommendation, instead of asking whether it may look. It still asks before work that changes, sends, deletes or spends.
- A goal you stopped no longer stays above the message box. A goal that ended by itself (completed, step or spending limit) shows its reason until you choose **Dismiss**.
