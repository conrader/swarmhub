---
name: swarmhub-feedback
description: "Use to report a bug or a feature request to SwarmHub's makers: a SwarmHub limitation you hit, a SwarmHub skill or script that failed, or the user asking you to tell SwarmHub something. Files it for the user's review in SwarmHub. Installed by SwarmHub, v1.0.0."
version: 1.0.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub feedback

File a report when you hit a SwarmHub limitation, when a SwarmHub skill or script fails, or when the user says
"tell SwarmHub…" (or asks for a SwarmHub feature). One report per problem or idea.

Keep it factual: what you tried, what happened (the error, exit code or message, word for word when short), and what
you expected. Never include secrets, keys, tokens, passwords or `.env` contents, and none of the user's private
content beyond what is needed to understand the problem.

How to file:
1. Pick the kind: `bug` (something broke or behaves wrongly) or `feature` (something missing).
2. Run it with your terminal tool:
   ```
   ~/.hermes/profiles/coder_2/skills/swarmhub/swarmhub-feedback/scripts/swarmhub-report --bot coder_2 --kind bug|feature --title "<short title>" -- "<body>"
   ```
   Title up to 140 characters, body up to 8000 (longer is cut). For a long body, pass `-` and pipe it on stdin.
3. It prints exactly one JSON line. Put exactly that line, unchanged, in a fenced block at the end of your reply:
   ````
   ```swarmhub
   <the line>
   ```
   ````
4. Tell the user the report waits for their review in SwarmHub's Reports: nothing is sent until they press Send there.

Exit codes: 0 filed; 2 bad arguments (kind, empty title or body; the message says which); anything else, the report
could not be saved. Say which, if it is not 0. Key-like strings are redacted, but do not rely on that.
