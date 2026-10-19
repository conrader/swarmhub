---
name: swarmhub-coding
description: "Use for any coding task: writing or changing code, work in a repository, tests, pull requests. Hands the task to a coding agent (Claude Code, Codex) through SwarmHub's code-job queue; supersedes the claude-code, codex and opencode skills. Installed by SwarmHub, v{{VERSION}}."
version: 1.2.0
author: SwarmHub
metadata:
  swarmhub:
    source: swarmhub
---

# SwarmHub coding

Use this for every coding task: writing or changing code, work in a repository, running and fixing tests, preparing a
pull request. Do not use the claude-code, codex or opencode skills; this one replaces them.

How to run a job:
1. Write the task as one clear, self-contained instruction (what to change, where, how to check it).
2. Start it as a background process of your terminal tool (its background option), with your workspace or the
   repository folder as `--dir`:
   ```
   {{SKILL_DIR}}/scripts/code-job --bot {{BOT}} --order {{CODING_ORDER}} --dir <workspace or repo folder> -- "<task>"
   ```
3. Wait for the process to finish. A job can take many minutes; when the box is busy it first waits for a free coding
   slot ("Waiting for a free coding slot…"). Do not start the same task twice.
4. Report the result in a few lines: what changed, what was checked, and the last `code-job:` line as it is (which
   agent ran, how long it waited and ran, its peak memory, and anything skipped).

Exit codes: 0 done; 124 the job ran out of time; 69 no coding agent could run (say which were skipped and why); any
other code is the agent's own failure, report its output. On exit 75 with `CODE_JOB_USE_DELEGATE` on stdout, do the
task with your own delegate_task (a sub-agent) instead.

Never print, read or copy `~/.hermes/swarmhub/claude.token`, and never set ANTHROPIC_API_KEY. Logins are SwarmHub's
Accounts sheet's job (`scripts/swarmhub-claude-login`, run by the manager bot): never run it or a login yourself.

Completion routing: when this task came from another bot, add `--origin <ordering-profile>` to code-job (or set
`SWARMHUB_ORDERING_BOT`). A Hermes terminal in `swarmhub-from-<sender>` also infers it from `HERMES_SESSION_ID`.
Use the sender of the original request, not the worker's own profile. Unknown/missing origin
falls back to `COORDINATOR=<profile>` in `~/.hermes/swarmhub/coding.conf` or `SWARMHUB_COORDINATOR`. Without either,
the completion remains pending until a coordinator is configured. Install swarmhub-messages alongside this skill.
Every exit publishes a private record in `~/.hermes/swarmhub/job-completions/job.*` before temporary output is removed.
The record contains routing, agent, exit/status, work directory and timings, never the task text or CLI output.
The messaging worker retries priority wakes until delivered, including after restart; no keys need copying.
A repeated completion carries the same job ID. Check that ID before repeating follow-up work. Exit 75 is a delegate
handoff, not a completed coding task. Exit zero reports CLI success; inspect artifacts before claiming completion.
