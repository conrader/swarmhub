# How bots communicate and take initiative

This is the behaviour SwarmHub promises. It is also the test plan: every rule below is either enforced in code and unit-tested, or measured with real agents before a release. Where it follows Grok Bot's published behaviour it says so.

## Who is who

- **You.** Your word overrides everything here.
- **The main bot** (star). One per server. It creates bots, coordinates, and is the only bot that reaches out to you unprompted.
- **Bots.** Each owns an area of work and has its own chat with you.
- **Helpers.** Short-lived agents under a bot. They talk only to their bot and disappear when done.

## Messages between bots

1. **Three kinds.** A bot writes to another bot to *ask* (it needs an answer), to *tell* (no answer expected), or to *hand off* (take this over and report when it is done).
2. **Asynchronous** (as Grok Bot). The sender does not wait. The receiver wakes, with its agent started if needed, handles the message and replies when it has something; the reply reaches the sender as its next message.
3. **Visible** (as Grok Bot). Every message and every reply appears in both bots' chats, marked with who sent it. Nothing passes between bots that you cannot read.
4. **One owner.** A piece of work belongs to one bot at a time. A hand-off moves it: the receiver accepts or declines with a reason. Whoever owns the work reports its result to the bot that handed it over and, when the work started with you, to you.
5. **Nothing is dropped.** Every ask and every hand-off ends in one of three ways, and the sender is told which: answered, declined, or not answered in time (default 10 minutes for an ask, 5 minutes to accept a hand-off).
6. **Follow-ups are allowed, loops are not.** Bots may go back and forth (Grok Bot sets no one-round rule), within hard limits: at most 8 messages between the same two bots for one piece of work, a chain of at most 4 bots, and a cap per bot per ten minutes. At a limit, both bots are told to bring the matter to you.
7. **Your instructions win** (as Grok Bot). "Don't message other bots, ask me first" is honoured; each bot also has a switch for it. Stopping a bot ends the exchanges it is part of, and the bots waiting on it are told.

## Initiative

1. **Who reaches out.** Only the main bot starts a conversation with you unprompted (as Grok Bot's primary Bot). Any bot may report the result of work it owns and ask you for what it needs.
2. **What the main bot does without being asked.** It offers to take on work it notices, it flags problems (a bot stuck at a prompt, a helper that stopped without an answer, a server that cannot be reached, a hand-off nobody accepted), and it follows up on work that was left unfinished.
3. **It offers first** (as Grok Bot). It never starts new work on its own decision; it proposes and waits for your yes. Finishing and reporting work that was already started is not new work. Before a risky action (deleting, sending, spending, deploying) a bot asks you.
4. **Planned check-ins.** A bot can plan to come back to something ("check the deploy in 30 minutes", "every weekday at 9"). Check-ins run on the server, so they fire with the Mac asleep. Each bot's planned check-ins are listed in its Details and can be cancelled. Limits: at least 5 minutes apart, at most 10 planned per bot. A one-off check-in always reports its outcome; a recurring one stays quiet when there is nothing to say.
5. **Open promises.** When a bot says it will do or report something later, that is recorded. An overdue promise is raised with the bot once, then with you.
6. **Notifications.** A message a bot sends on its own raises its unread mark and a macOS notification. Each bot has a Notifications switch (alerts only) and a "Takes initiative" switch (check-ins and offers).

## How this is made to hold

- **Enforced in code, unit-tested:** delivery and visibility, the three kinds, ownership, the three endings and their time limits, the limits on follow-ups and chains, stop, the planned check-ins and their limits, the switches.
- **Depends on the model, so measured:** whether a bot chooses the right kind, reports back, offers instead of acting, stays quiet when it should. Each scenario below is run ten times with a real Claude Code agent and ten times with a real Codex agent. The bar is 9 of 10 for each. A scenario under the bar is not shipped as working; the results table is published with the release notes.

| # | Scenario | Passes when |
|---|---|---|
| 1 | A asks B a question | B's answer reaches A, both chats show it, A uses it |
| 2 | A tells B something | B does not reply to A; nothing else is sent |
| 3 | A hands work to B | B accepts, does it, and reports to A and to you |
| 4 | B declines a hand-off | A is told why and brings it to you |
| 5 | B needs a clarification | B asks A, A answers, B finishes; limits respected |
| 6 | Two bots keep going | The exchange stops at the limit and is brought to you |
| 7 | You stop B mid-exchange | A is told; nothing further is sent |
| 8 | "Don't message other bots" | A asks you instead |
| 9 | The main bot notices work | It offers; it does not start |
| 10 | A helper stops without an answer | The main bot flags it to you |
| 11 | A planned check-in, Mac app closed | It fires, and the result is waiting when you return |
| 12 | A recurring check-in with nothing new | No message |
| 13 | A risky action | The bot asks you first |
