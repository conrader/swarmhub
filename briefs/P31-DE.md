# P31 D + E — Sub-agent model and box capacity

Konrad, 2026-10-15: "build P31 D and E". Parts D and E of the accepted P31 (`briefs/P31.md`), with the build defaults
below. Hermes stays vanilla: read-only shell recipes the manager runs, `hermes config set` through the existing P30
recipe, one SwarmHub file on the box (`~/.hermes/swarmhub/coding.conf`, already read by `code-job`), and app UI.

## Facts (main 6f4bc8b; Konrad's box, read-only, 2026-10-15)
- The P30 model recipe in `Resources/BotManager/manager-hermes.md` already takes `KM=delegation.model
  KP=delegation.provider` ("only when asked"). `ManagementIntent.changeModel` is the "Change model…" entry.
- Hermes 0.22 `tools/delegate_tool.py`: "Children inherit the parent model unless pinned via delegation.provider /
  delegation.model in config.yaml." Konrad's default config has `delegation: model: gpt-6.1-sol, provider: openai-codex`.
- `code-job` reads `SLOTS=<n>` from `~/.hermes/swarmhub/coding.conf` (missing/0 → 1) and appends one TSV line per job to
  `~/.hermes/swarmhub/coding-jobs.log`: `iso-time bot agent waited_s ran_s peak_mb exit skipped`.
- The Overview line today is "Sub-agents: <box only>" (`ModelRolesReadout.swift:35`); Settings → Models shows
  "Sub-agents" from `subAgentSummary` (`SettingsModelsPane.swift:41`).
- Manager core is 4,391 B and must stay small: new recipes go in `Resources/BotManager/recipes/` (loaded on demand like
  `box.md`/`accounts.md`); the core gains at most one pointer line (≤ 200 B).

## D. Sub-agent model
1. **Read: op `models`.** A read-only recipe (new `recipes/models.md`) prints, for `default` and every profile,
   `model.default`, `model.provider`, `delegation.model`, `delegation.provider` read from config.yaml with sed (same
   section match as the P30 skip check; no `hermes` CLI start, no Python):
   `{"op":"models","list":[{"name":"jarvis","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"","sub_provider":""}]}`.
   The parser accepts only valid profile names and model/provider ids (`[A-Za-z0-9._:/-]`, ≤ 100), drops bad rows.
   The app stores the report per connection with its time (persisted with the other bot info; survives restart).
2. **Show.** Overview "Sub-agents:" line and the Settings → Models Sub-agents line:
   - pinned: "Sub-agents: gpt-6.1-sol (reported 15 Oct)";
   - empty `sub_model`: "Sub-agents: same as this bot (gpt-5.6-terra)";
   - no report yet: today's box-only text plus "Check" (asks the manager for the `models` op, silently, like the
     `bots` list refresh).
   Sub-agents off (P11 `delegation` toolset) still wins and says so.
3. **Change.** "Change sub-agent model…" in Manage bots (next to "Change model…", Hermes managers only) and a
   "Change…" button on the Overview Sub-agents line (bot prefilled). The sheet is the "Change model…" sheet with the
   role fixed to sub-agents: model (catalog picker), provider, bots (this one / some / all), plus "Same as each bot's
   model" which clears the pin (`hermes config set delegation.model ""` and `delegation.provider ""`; verified on the box
   in a temp HERMES_HOME: rc 0, writes `model: ''`; the recipe's skip check and the `models` reader must treat `''`,
   `""` and a missing key as empty). It sends the P30 recipe with `KM=delegation.model KP=delegation.provider`;
   the manager still asks Konrad first. Copy says what it affects: "Model for sub-agents this bot starts. Coding jobs
   use the coding agent instead."
4. **Refresh.** When the manager's reply reports the model log DONE (P32 item 12), also request `models` and refresh
   the lines. Wording note: "coding model" in P31's text is this sub-agent model; the UI says "sub-agent model" because
   coding jobs run on the Coding agent (Claude Code / Codex) set in Settings → Models.

## E. Box capacity
1. **Read: op `box_capacity`.** A read-only probe (in `recipes/models.md` or a new `recipes/capacity.md`) prints
   `{"op":"box_capacity","cpus":2,"mem_total_mb":3891,"mem_avail_mb":1380,"disk_free_mb":17400,"load1":"0.42",
   "slots":1|null,"jobs":[["2026-10-15T01:02:03Z",waited,ran,peak_mb,exit],…]}` from `nproc`, `/proc/meminfo`,
   `df -Pm ~`, `/proc/loadavg`, `coding.conf` and the last 200 log lines (bot/agent dropped; nothing else read).
   Parser: numbers in range, at most 200 job rows, bad rows dropped.
2. **Compute** (pure, tested): job RAM = max peak of the last 20 jobs, default 600 MB with fewer than 3 jobs;
   `advised = max(1, min(cpus, floor((mem_avail_mb − 512) / job_ram)))`; week stats from jobs in the last 7 days
   (count, average and longest wait). Advice:
   - average wait ≥ 60 s and advised > slots: "Jobs waited N min on average this week. This box can run <advised>."
   - average wait ≥ 60 s and advised ≤ slots: "Jobs waited N min on average this week; a box with <2×cpus> CPUs and
     <2×RAM> GB would run <computed for that size>."
   - else no advice line.
3. **Show.** Settings → Models, under Coding agent, per Hermes connection: "This box: 2 CPUs, 3.8 GB — 1 coding job at
   a time (set by you | advised)", the advice line, "Checked 15 Oct 09:12", buttons "Check" and "Set limit…".
   Nothing about other boxes; OpenClaw connections show nothing.
4. **Apply.** "Use advised" / "Set limit…" (1…cpus×2, stepper) asks the manager to write
   `~/.hermes/swarmhub/coding.conf` (`SLOTS=<n>`, mode 0600, other lines kept) with a recipe in the same file; the
   manager asks Konrad first like other box writes; its reply carries `{"op":"box_capacity",…}` again so the line
   updates. Running jobs are not touched; the new limit applies to the next job.

## Tests and done means
Parser tests for both ops (good, hostile, oversize), the capacity computation and advice table, recipe text tests (no
`hermes` start in the read recipes; skip check with empty value; core size limit ≤ 4,600 B), the empty-pin clear, the
DONE→refresh path. A recipe smoke in `Tests/Scripts/` running both read recipes against a temp HOME with fixture
config.yaml files and a fixture log. Build exit 0, `swift test` green twice on a quiet Mac, renders of the Overview
Sub-agents line (three states), the sheet, and the Settings capacity block (no report, advised, with advice), looked
at. No file over 500 lines. Live check on Konrad's box stays in Part F.

## Wording (Konrad, 2026-10-15: "coding")
The UI calls `delegation.model` the **coding model**, not "sub-agent model": menu "Change coding model…", button
"Change…", sheet title "Coding model", Overview/Settings line "Coding model: gpt-6.1-sol (reported 15 Oct)" /
"Coding model: same as this bot (gpt-5.6-terra)". Help line: "Used by sub-agents this bot starts, and for coding jobs
when no coding agent (Claude Code, Codex) can run." Sub-agents off still says so on that line. This replaces the
wording note in D4.
