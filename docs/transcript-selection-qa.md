# macOS transcript selection QA

Use a logged-in macOS desktop with the Swift toolchain required by this checkout. Run from the repository root.

```sh
swift test --filter 'Transcript(Range|Text)Tests'
swift test --filter MessageSelectionTests
SWARMHUB_POINTER_QA=1 swift test --filter TranscriptPointerTests
```

The last command opens a direct chat and then a group chat using a temporary store, mock bot, isolated defaults, and in-memory key store. It sends pointer and Command-key events to those app windows and reads the system clipboard. Leave the fixture window focused. The test replaces the clipboard contents.

The fixture contains 96 older user rows followed by a Markdown reply with two bullets, a link, code, a table, and a hidden app block. A final user message reads “Closing sentinel”. The test drags from just before “checks” in the first bullet to just after “Closing”, repeats in reverse, and checks the highlighted endpoint ranges and the exact pasteboard string in each direction. The expected text is below. Table columns have one tab between them.

```text
checks the queue
• Beta checks the log

let count = 2

Owner	State
Ada	Ready

Closing
```

A third drag starts after “Closing” and holds at the top edge until “History 000” appears. The fixture releases just before “000” and compares the clipboard with every intervening row in reading order. It also checks transcript Select All, then moves focus into the composer and checks its native Select All and Copy. Each shortcut is sent to the window. Copy assertions require the pasteboard change count to advance.

The range tests exercise a reverse selection over 3,017 message IDs, partial UTF-16 runs, streaming growth, and inserting older rows. The text tests check rendered Markdown against clipboard offsets, omit card actions and hidden payloads, and check isolation when the same message ID appears in another conversation.
