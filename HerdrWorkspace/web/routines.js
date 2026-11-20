(() => {
  "use strict";

  const state = { mode: "list", item: null, draft: null, proposal: null, owner: null, destination: null, editing: false, working: false, revision: 0, polling: false };
  const proposalStatus = document.createElement("p");
  proposalStatus.id = "routine-proposal-status";
  proposalStatus.className = "subtle";
  proposalStatus.setAttribute("role", "status");
  const proposalDismiss = document.createElement("button");
  proposalDismiss.id = "routine-proposal-dismiss";
  proposalDismiss.type = "button";
  proposalDismiss.textContent = "Dismiss proposal";
  $("routine-setup-note").after(proposalStatus, proposalDismiss);
  proposalStatus.hidden = proposalDismiss.hidden = true;
  let fromAttention = false;
  let filterField = 0;
  const eligible = () => app.online ? app.agents.filter(live) : [];
  const routineState = { active: "Active", paused: "Paused", archived: "Archived" };
  const hookKinds = ["webhook", "github", "slack"];
  const hookLabels = { github:"On GitHub issue or pull request", slack:"On Slack app mention" };
  const runState = { ...deliveryLabel, skipped: "Skipped" };
  const key = (item) => idOf(item.target);
  const profileOf = (agent) => window.agentProfiles.profileFor(idOf(agent), app.core);
  const ownerName = (item) => app.profiles.find((profile) => profile.id === item.profile_id)?.name
    || window.agentProfiles.profileFor(key(item), item.core)?.name || item.agent;
  const draftAgents = (draft) => eligible().filter((agent) => profileOf(agent)?.id === draft.profile_id);
  const proposalAgents = ({source, item}) => eligible().filter((agent) =>
    (source.core === app.core && idOf(agent) === source.key)
      || (item.profile_id !== null && profileOf(agent)?.id === item.profile_id));
  const ownerAgents = () => eligible().filter((agent) => !state.owner ||
    (state.owner.key ? idOf(agent) === state.owner.key : profileOf(agent)?.id === state.owner.profile));

  function scheduleLabel(schedule) {
    if (schedule.kind === "webhook") return hookLabels[schedule.source] || "On webhook";
    if (schedule.kind === "interval") return `Every ${schedule.minutes} minute${schedule.minutes === 1 ? "" : "s"}`;
    const time = [schedule.hour, schedule.minute].map((n) => String(n).padStart(2, "0")).join(":");
    return `${schedule.weekdays ? "Weekdays" : "Daily"} at ${time} · ${schedule.timezone || "Follows the user's time zone"}`;
  }

  function nextLabel(item) {
    if (item.schedule.kind === "webhook" && item.state === "active") {
      return ({github:"Waiting for a GitHub event", slack:"Waiting for a Slack mention"})[item.schedule.source] || "Waiting for a webhook";
    }
    if (item.next_at === null) return routineState[item.state];
    return displayDate(item.next_at);
  }

  function mode(mode, label) {
    if (mode !== "detail") clearWebhookKey();
    if (mode !== "form") {
      state.proposal = null;
      proposalStatus.hidden = proposalDismiss.hidden = true;
    }
    ++state.revision;
    state.mode = mode;
    $("routine-heading").textContent = label;
    $("routine-list-view").hidden = mode !== "list";
    $("routine-detail").hidden = mode !== "detail";
    $("routine-import-detail").hidden = mode !== "imported";
    $("routine-form").hidden = mode !== "form";
    show("routine-notice", "");
    return state.revision;
  }

  function open(owner = null, profile = null) {
    fromAttention = false;
    state.owner = owner || profile ? { core: app.historyCore, key: owner ? idOf(owner) : null,
      name: profile?.name || title(owner), profile: profile?.id } : null;
    $("routine-dialog").showModal();
    void showList();
  }

  function openSearchResult() {
    const dialog = $("routine-dialog");
    if (!app.authorized || dialog.open) return null;
    fromAttention = false;
    state.owner = state.item = state.draft = null;
    $("routine-archived").checked = false;
    dialog.showModal();
    return dialog;
  }

  async function openById(id) {
    const dialog = openSearchResult();
    if (!dialog) return;
    await showDetail(id);
    if (dialog.open && state.item?.id === id && state.item.state === "archived") $("routine-archived").checked = true;
  }

  async function openImportedById(id) {
    const dialog = openSearchResult();
    if (!dialog) return;
    const revision = mode("", "Imported routine draft");
    show("routine-notice", "Loading routine draft…");
    try {
      const drafts = await api("/api/routines/imported");
      if (!app.authorized || !dialog.open || revision !== state.revision) return;
      const draft = drafts.find((item) => item.id === id);
      if (draft) showDraft(draft);
      else show("routine-notice", "This imported routine draft is no longer available.");
    } catch (error) {
      if (app.authorized && dialog.open && revision === state.revision) show("routine-notice", error.message);
    }
  }

  async function openProposal(source, message) {
    const dialog = $("routine-dialog");
    if (dialog.open || !app.authorized) return;
    state.owner = state.item = state.draft = null;
    fromAttention = false;
    const path = source.path + "/routine-proposals/" + message;
    const revision = mode("", "Review proposed routine");
    dialog.showModal();
    show("routine-notice", "Loading routine proposal…");
    try {
      const item = await api(path);
      if (!dialog.open || revision !== state.revision) return;
      if (item.state === "saved") { await showDetail(item.routine); return; }
      if (item.state !== "pending") { show("routine-notice", "This proposal was dismissed."); return; }
      edit(null, null, {path, source, message, item});
    } catch (error) {
      if (dialog.open && revision === state.revision) show("routine-notice", error.message);
    }
  }

  function updateProposalAvailability() {
    if (!state.proposal || state.mode !== "form") return;
    const options = proposalAgents(state.proposal).map((agent) => [
      idOf(agent), profileOf(agent)?.name || title(agent),
    ]);
    const current = $("routine-agent").value;
    const signature = JSON.stringify(options);
    if (state.proposal.options !== signature) {
      state.proposal.options = signature;
      $("routine-agent").replaceChildren(...(options.length
        ? options.map(([session, label]) => new Option(label, session))
        : [new Option("No eligible session", "")]));
      if (options.some(([session]) => session === current)) $("routine-agent").value = current;
    }
    const enabled = Boolean(options.length && app.authorized && !state.working);
    $("routine-agent").disabled = $("routine-skill").disabled = $("routine-save").disabled = !enabled;
    proposalDismiss.disabled = !app.authorized || state.working;
    const message = options.length ? "" : "Start or reconnect a session for this agent to save. You can review or dismiss this proposal now.";
    if (proposalStatus.textContent !== message) proposalStatus.textContent = message;
    proposalStatus.hidden = !message;
  }

  proposalDismiss.addEventListener("click", async () => {
    const proposal = state.proposal;
    if (!proposal || state.working || !app.authorized) return;
    state.working = true;
    updateProposalAvailability();
    show("routine-form-error", "");
    try {
      await api(proposal.path + "/dismiss", {});
      markRoutineProposal(proposal.source, proposal.message, "dismissed");
      $("routine-dialog").close();
    } catch (error) {
      show("routine-form-error", error.message);
    } finally {
      state.working = false;
      updateProposalAvailability();
    }
  });

  async function showList() {
    state.item = null;
    state.draft = null;
    const revision = mode("list", state.owner ? `Routines for ${state.owner.name}` : "Routines");
    $("routine-new").disabled = !ownerAgents().length;
    $("routine-list").replaceChildren();
    $("routine-imports").hidden = true;
    show("routine-notice", "Loading routines…");
    try {
      const [routines, drafts] = await Promise.all([api("/api/routines"), api("/api/routines/imported")]);
      if (revision !== state.revision) return;
      const rows = routines.filter((item) => {
        if (state.owner) {
          const matches = item.profile_id && state.owner.profile ? item.profile_id === state.owner.profile
            : item.core === state.owner.core && key(item) === state.owner.key;
          if (!matches) return false;
        }
        return $("routine-archived").checked || item.state !== "archived";
      }).map((item) => {
        const row = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = item.name;
        const detail = document.createElement("small");
        detail.textContent = `${ownerName(item)} · ${scheduleLabel(item.schedule)} · ${routineState[item.state]}`;
        button.append(detail);
        button.addEventListener("click", () => showDetail(item.id));
        row.append(button);
        return row;
      });
      $("routine-list").replaceChildren(...rows);
      const imported = drafts.filter((draft) => !state.owner || draft.profile_id === state.owner.profile);
      $("routine-drafts").replaceChildren(...imported.map((draft) => {
        const row = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = draft.name;
        const detail = document.createElement("small");
        detail.textContent = `${draft.profile_name} · Needs setup`;
        button.append(detail);
        button.addEventListener("click", () => showDraft(draft));
        row.append(button);
        return row;
      }));
      $("routine-imports").hidden = !imported.length;
      show("routine-notice", rows.length || imported.length ? "" : "No routines to show.");
    } catch (error) {
      if (revision === state.revision) show("routine-notice", error.message);
    }
  }

  function showDraft(draft) {
    state.draft = draft;
    mode("imported", draft.name);
    $("routine-import-owner").textContent = draft.profile_name;
    $("routine-import-schedule").textContent = draft.schedule ? scheduleLabel(draft.schedule)
      : draft.source_hint ? `${draft.source_hint} · Choose a schedule manually` : "Not included in the export";
    $("routine-import-task").textContent = draft.task || "Not included in the export";
    $("routine-import-dismiss").disabled = false;
    updateDraftAvailability();
    $("routine-import-back").focus();
  }

  function updateDraftAvailability() {
    const running = Boolean(state.draft && draftAgents(state.draft).length);
    $("routine-import-setup").disabled = !running || state.working;
    $("routine-import-help").textContent = running
      ? "Review the task and schedule before saving this routine as paused."
      : "Start a session for this profile to finish setting up the routine.";
  }

  async function showDetail(id) {
    clearWebhookKey();
    $("routine-webhook").hidden = true;
    $("routine-move-box").hidden = true;
    state.item = null;
    state.destination = null;
    state.draft = null;
    $("routine-runs").replaceChildren();
    $("routine-review-view").hidden = true;
    $("routine-review-items").replaceChildren();
    show("routine-review-status", "");
    $("routine-back").textContent = fromAttention ? "Back to Needs attention" : "Back to routines";
    $("routine-owner").textContent = $("routine-session").textContent = $("routine-when").textContent = $("routine-next").textContent = $("routine-instructions").textContent = "";
    for (const action of ["toggle", "test", "edit", "archive"]) $("routine-" + action).disabled = true;
    mode("detail", "Routine");
    show("routine-notice", "Loading routine…");
    await updateDetail(id);
  }

  async function openReview(id, entry) {
    const dialog = $("routine-dialog");
    if (state.working) throw new Error("Wait for the current routine action to finish.");
    fromAttention = true;
    state.owner = null;
    if (!dialog.open) dialog.showModal();
    await showDetail(id);
    if (!dialog.open || state.item?.id !== id) return;
    const details = [...$("routine-review-items").querySelectorAll("li[data-review-id]")]
      .find((row) => row.dataset.reviewId === String(entry))?.querySelector("details");
    if (details) {
      details.open = true;
      details.querySelector("summary").focus();
    } else {
      show("routine-notice", "This event was already reviewed or is no longer available.");
      $("routine-back").focus();
    }
  }

  async function updateDetail(id) {
    if (state.mode !== "detail") return;
    const revision = state.revision;
    try {
      const result = await api(`/api/routines/${id}`);
      if (revision !== state.revision) return;
      const item = state.item = result.routine;
      $("routine-heading").textContent = item.name;
      $("routine-owner").textContent = ownerName(item);
      const current = item.core === app.core && eligible().some((agent) => idOf(agent) === key(item));
      $("routine-session").textContent = item.target.address + (current ? " · Running" : " · Not connected");
      $("routine-when").textContent = scheduleLabel(item.schedule);
      $("routine-next").textContent = nextLabel(item);
      $("routine-instructions").textContent = item.task;
      $("routine-webhook").hidden = item.schedule.kind !== "webhook";
      if (!$("routine-webhook").hidden) {
        const github = item.schedule.source === "github";
        const slack = item.schedule.source === "slack";
        $("routine-webhook-url").value = new URL(slack ? "/hooks/slack" : "/hooks/routines/" + item.id + (github ? "/github" : ""), location.origin).href;
        $("routine-webhook-heading").textContent = slack ? "Slack Events API" : github ? "GitHub webhook" : "Webhook";
        $("routine-webhook-help").textContent = slack
          ? "The Slack app must subscribe to app mentions. Forward signed Events API requests to the local receiver."
          : github
          ? "Use the generated key as GitHub’s webhook secret. Your local relay must forward the original JSON and delivery headers."
          : "Send Authorization: Bearer <key> and a unique Idempotency-Key for each event. An optional JSON object is passed to the agent as data.";
        $("routine-webhook-key").hidden = slack;
        $("routine-webhook-key").disabled = item.state === "archived" || state.working;
        $("routine-webhook-key").textContent = item.webhook_ready ? "Rotate key" : "Generate key";
        $("routine-webhook-state").textContent = item.state === "archived" ? "This webhook is disabled."
          : slack ? result.slack_ready ? "Slack signing is configured." : "A Slack signing credential isn’t available."
          : item.webhook_ready ? "A key is configured." : "Generate a key before sending events.";
        const filters = item.schedule.filters || [];
        $("routine-webhook-matching").textContent = filters.length ? "Only runs when all conditions match:" : "Runs for any valid webhook event.";
        $("routine-webhook-filters").hidden = !filters.length;
        $("routine-webhook-filters").replaceChildren(...filters.map(({field, equals}) => {
          const rule = document.createElement("li");
          rule.textContent = field + " equals “" + equals + "”";
          return rule;
        }));
      }
      $("routine-toggle").textContent = item.state === "active" ? "Pause" : "Resume";
      const locked = state.working || item.state === "archived";
      const next = item.profile_id && item.state !== "archived" && eligible().find((agent) =>
        (item.core !== app.core || idOf(agent) !== key(item)) && profileOf(agent)?.id === item.profile_id);
      state.destination = next ? { core:app.core, target:{address:next.address,created_ms:next.created_ms} } : null;
      $("routine-move-box").hidden = !state.destination;
      if (state.destination) {
        $("routine-move-help").textContent = "Move to session " + next.address + ". This pauses the routine until you resume it.";
      }
      $("routine-move").disabled = locked || result.runs.some((run) => run.state === "pending");
      $("routine-toggle").disabled = $("routine-edit").disabled = $("routine-archive").disabled = locked;
      $("routine-test").disabled = locked || !app.online || item.core !== app.core
        || !app.agents.some((agent) => idOf(agent) === key(item) && live(agent))
        || result.runs.some((run) => run.state === "pending");
      renderReviews(item, result.reviews || [], result.runs.some((run) => run.state === "pending"));
      const signature = JSON.stringify(result.runs);
      if ($("routine-runs").dataset.signature !== signature || !$("routine-runs").children.length) {
        $("routine-runs").replaceChildren(...result.runs.map((run) => {
          const row = document.createElement("li");
          const label = document.createElement("strong");
          label.textContent = `${({test:"Test",webhook:"Webhook",schedule:"Scheduled"})[run.kind]} · ${runState[run.state] || run.state}`;
          const detail = document.createElement("small");
          detail.textContent = `${displayDate(run.at_ms)}${run.detail ? " · " + run.detail : ""}`;
          row.append(label, detail);
          if (run.result || run.awaiting_result) {
            const outcome = document.createElement("strong");
            outcome.className = "routine-result-state";
            outcome.textContent = run.result
              ? (run.result.state === "succeeded" ? "Outcome: Succeeded" : "Outcome: Failed")
              : "Waiting for the agent to report an outcome";
            row.append(outcome);
          }
          if (run.result) {
            const summary = document.createElement("p");
            summary.className = "routine-result-summary";
            summary.textContent = run.result.summary;
            row.append(summary);
          }
          if (run.conversation && (run.task_id || run.result)) {
            const result = document.createElement("button");
            result.type = "button";
            result.textContent = run.result ? "View result" : "View task";
            result.addEventListener("click", () => {
              if (!$("library").open) $("library").showModal();
              showArchive(run.conversation, run.result?.id || run.task_id);
            });
            row.append(result);
          }
          return row;
        }));
        $("routine-runs").dataset.signature = signature;
      }
      if (!$("routine-runs").children.length) {
        const empty = document.createElement("li");
        empty.textContent = "No runs yet.";
        $("routine-runs").append(empty);
      }
      if ($("routine-notice").textContent === "Loading routine…") show("routine-notice", "");
    } catch (error) {
      if (revision === state.revision) show("routine-notice", error.message);
    }
  }

  function renderReviews(item, entries, pending) {
    const root = $("routine-review-items");
    const canRun = app.online && app.core === item.core && item.state === "active" && !pending &&
      app.agents.some((agent) => idOf(agent) === key(item) && live(agent) &&
        !["working", "blocked"].includes(agent.status?.state));
    $("routine-review-view").hidden = item.state === "archived" || (!entries.length && !item.schedule.review);
    const signature = JSON.stringify([entries, canRun, state.working]);
    if (root.dataset.signature === signature && root.children.length) return;
    root.dataset.signature = signature;
    if (!entries.length) {
      const empty = document.createElement("li");
      empty.textContent = "No events awaiting review.";
      root.replaceChildren(empty);
      return;
    }
    const expanded = new Set([...root.querySelectorAll("li:has(details[open])")].map((row) => row.dataset.reviewId));
    root.replaceChildren(...entries.map((entry) => {
      const row = document.createElement("li");
      row.dataset.reviewId = entry.id;
      const details = document.createElement("details");
      details.open = expanded.has(String(entry.id));
      const summary = document.createElement("summary");
      summary.textContent = "Event received " + displayDate(entry.at_ms);
      const payload = document.createElement("pre");
      payload.tabIndex = 0;
      payload.textContent = entry.payload ? JSON.stringify(entry.payload, null, 2) : "No JSON payload.";
      details.append(summary, payload);
      const controls = document.createElement("div");
      controls.className = "routine-actions";
      const actions = [["Approve and run","approve"], ["Dismiss","dismiss"]];
      for (const [label, action] of actions) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = label;
        button.disabled = state.working || (action === "approve" && (!canRun || entry.stale));
        button.addEventListener("click", () => resolveReview(item.id, entry.id, action));
        controls.append(button);
      }
      const info = document.createElement("p");
      info.className = "subtle";
      info.textContent = entry.stale ? "The routine changed after this event arrived. Dismiss it instead."
        : !canRun ? "Resume the routine and wait for its agent to be available before approving." : "";
      info.hidden = !info.textContent;
      row.append(details, info, controls);
      return row;
    }));
  }

  async function resolveReview(id, entry, action) {
    if (state.working) return;
    const revision = state.revision;
    state.working = true;
    for (const button of $("routine-review-items").querySelectorAll("button")) button.disabled = true;
    show("routine-review-status", "");
    try {
      await api(`/api/routines/${id}/reviews/${entry}`, action);
      void window.workspaceAttention?.refresh();
      if (revision === state.revision) show("routine-review-status", action === "approve" ? "Approved. Check Run history for delivery." : "Event dismissed.");
    } catch (error) {
      if (revision === state.revision) show("routine-review-status", error.message);
    } finally {
      state.working = false;
      if (revision === state.revision) {
        delete $("routine-review-items").dataset.signature;
        await updateDetail(id);
      }
    }
  }

  function edit(item = null, draft = null, proposal = null) {
    const agents = proposal ? proposalAgents(proposal) : draft ? draftAgents(draft) : ownerAgents();
    if (!item && !proposal && !agents.length) return;
    state.editing = Boolean(item);
    state.draft = draft;
    state.proposal = proposal;
    mode("form", proposal ? "Review proposed routine" : item ? "Edit routine" : draft ? "Set up imported routine" : "New routine");
    $("routine-name").value = proposal?.item.name || item?.name || draft?.name || "";
    $("routine-task").value = proposal?.item.task || item?.task || draft?.task || "";
    $("routine-agent-field").hidden = Boolean(item);
    $("routine-agent").replaceChildren(...agents.map((agent) => new Option(profileOf(agent)?.name || title(agent), idOf(agent))));
    const schedule = proposal?.item.schedule || item?.schedule || draft?.schedule;
    $("routine-kind").value = schedule?.kind === "webhook" ? schedule.source || "webhook" : schedule?.kind === "daily" ? schedule.weekdays ? "weekdays" : "daily"
      : draft && !schedule ? "" : "interval";
    $("routine-minutes").value = schedule?.minutes ?? 60;
    $("routine-time").value = schedule?.kind === "daily"
      ? [schedule.hour, schedule.minute].map((value) => String(value).padStart(2, "0")).join(":") : "09:00";
    $("routine-follow-zone").checked = !schedule?.timezone;
    $("routine-zone").value = schedule?.timezone || app.timezone || "UTC";
    $("routine-filter-rules").replaceChildren();
    $("routine-review-enabled").checked = Boolean(schedule?.review);
    for (const filter of schedule?.filters || []) addFilter(filter);
    $("routine-filter-add").disabled = $("routine-filter-rules").childElementCount >= 4;
    $("routine-save").textContent = draft || proposal ? "Save paused routine" : "Save routine";
    $("routine-setup-note").hidden = !draft && !proposal;
    $("routine-agent").disabled = $("routine-skill").disabled = $("routine-save").disabled = false;
    proposalDismiss.hidden = !proposal;
    show("routine-form-error", "");
    toggleFields();
    updateProposalAvailability();
    $("routine-name").focus();
  }

  function toggleFields() {
    const interval = $("routine-kind").value === "interval";
    const calendar = ["daily","weekdays"].includes($("routine-kind").value);
    $("routine-interval-field").hidden = !interval;
    $("routine-time-field").hidden = !calendar;
    const hook = $("routine-kind").value;
    $("routine-filter-editor").hidden = $("routine-filter-editor").disabled = !hookKinds.includes(hook);
    $("routine-filter-github").hidden = hook !== "github";
    $("routine-filter-slack").hidden = hook !== "slack";
    if (hook === "slack" && !$("routine-filter-rules").children.length) {
      for (const field of ["team_id", "channel"]) addFilter({field});
    }
    $("routine-minutes").disabled = !interval;
    $("routine-minutes").required = interval;
    $("routine-time").disabled = !calendar;
    $("routine-time").required = calendar;
    $("routine-follow-zone").disabled = !calendar;
    const pinned = calendar && !$("routine-follow-zone").checked;
    $("routine-zone-field").hidden = $("routine-zone").disabled = !pinned;
    $("routine-zone").required = pinned;
  }

  function addFilter({field = "", equals = ""} = {}, focus = false) {
    const rules = $("routine-filter-rules");
    if (rules.childElementCount >= 4) return;
    const row = document.createElement("fieldset");
    const legend = document.createElement("legend");
    legend.textContent = "Condition";
    row.append(legend);
    for (const [key, name, value, max] of [["field", "JSON field", field, 128], ["equals", "Equals text", equals, 160]]) {
      const input = document.createElement("input");
      input.id = "routine-filter-" + ++filterField;
      input.dataset.rule = key;
      input.value = value;
      input.maxLength = max;
      input.required = true;
      const label = document.createElement("label");
      label.htmlFor = input.id;
      label.textContent = name;
      row.append(label, input);
    }
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "Remove condition";
    remove.addEventListener("click", () => {
      row.remove();
      $("routine-filter-add").disabled = false;
      $("routine-filter-add").focus();
    });
    row.append(remove);
    rules.append(row);
    $("routine-filter-add").disabled = rules.childElementCount >= 4;
    if (focus) row.querySelector("input").focus();
  }

  $("routine-filter-add").addEventListener("click", () => addFilter({}, true));
  $("routines-open").addEventListener("click", () => open());
  $("agent-routines").addEventListener("click", () => open(active(), window.agentProfiles.current()));
  $("routine-close").addEventListener("click", () => { if (!state.working) $("routine-dialog").close(); });
  $("routine-dialog").addEventListener("cancel", (event) => { if (state.working) event.preventDefault(); });
  $("routine-dialog").addEventListener("close", () => {
    if ($("routine-dialog").open) return;
    ++state.revision;
    state.proposal = null;
    clearWebhookKey();
  });
  $("routine-new").addEventListener("click", () => edit());
  $("routine-back").addEventListener("click", () => {
    if (!fromAttention) { void showList(); return; }
    $("routine-dialog").close();
    $("attention-open").click();
  });
  $("routine-import-back").addEventListener("click", showList);
  $("routine-import-setup").addEventListener("click", () => { if (state.draft && !state.working) edit(null, state.draft); });
  $("routine-import-dismiss").addEventListener("click", async () => {
    if (!state.draft || state.working) return;
    state.working = true;
    $("routine-import-dismiss").disabled = true;
    updateDraftAvailability();
    try {
      await api(`/api/routines/imported/${state.draft.id}/dismiss`, {});
      await showList();
    } catch (error) {
      show("routine-notice", error.message);
    } finally {
      state.working = false;
      $("routine-import-dismiss").disabled = false;
      if (state.mode === "imported") updateDraftAvailability();
    }
  });
  $("routine-archived").addEventListener("change", showList);
  $("routine-kind").addEventListener("change", toggleFields);
  $("routine-follow-zone").addEventListener("change", toggleFields);
  $("routine-edit").addEventListener("click", () => edit(state.item));
  $("routine-skill").addEventListener("click", () => {
    const current = state.editing && state.item;
    const pick = current ? null : eligible().find((agent) => idOf(agent) === $("routine-agent").value);
    const context = current
      ? { core: current.core, name: current.agent, target: current.target }
      : window.workspaceSkills?.scope(pick);
    if (!context) { show("routine-form-error", "Choose an agent before adding a skill."); return; }
    window.workspaceSkills?.open(context, (skill) => state.mode === "form"
      ? window.workspaceSkills.append($("routine-task"), skill, 12288)
      : "This routine draft is no longer open.");
  });
  $("routine-cancel").addEventListener("click", () => {
    if (state.working) return;
    if (state.proposal) { $("routine-dialog").close(); return; }
    if (state.editing && state.item) void showDetail(state.item.id);
    else if (state.draft) showDraft(state.draft);
    else void showList();
  });
  $("routine-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (state.working || !app.authorized) return;
    const proposal = state.proposal;
    const name = $("routine-name").value;
    const task = $("routine-task").value;
    if (!name.trim() || !taskOk(task) || new TextEncoder().encode(task).length > 12288) {
      show("routine-form-error", "Enter a name and instructions up to 12 KiB.");
      return;
    }
    const kind = $("routine-kind").value;
    if (!kind) { show("routine-form-error", "Choose a schedule."); return; }
    const [hour, minute] = $("routine-time").value.split(":").map(Number);
    const schedule = hookKinds.includes(kind) ? {kind:"webhook"} : kind === "interval" ? { kind, minutes: Number($("routine-minutes").value) }
      : { kind: "daily", hour, minute, ...($("routine-follow-zone").checked ? {} : { timezone: $("routine-zone").value.trim() }), weekdays: kind === "weekdays" };
    if (schedule.kind === "webhook") {
      if (kind !== "webhook") schedule.source = kind;
      if ($("routine-review-enabled").checked) schedule.review = true;
      schedule.filters = [...$("routine-filter-rules").children].map((row) => ({
        field: row.querySelector('[data-rule="field"]').value.trim(),
        equals: row.querySelector('[data-rule="equals"]').value,
      }));
    }
    const body = { name, task, schedule };
    if (!state.editing) {
      const options = proposal ? proposalAgents(proposal) : state.draft ? draftAgents(state.draft) : ownerAgents();
      const owner = options.find((agent) => idOf(agent) === $("routine-agent").value);
      if (!owner) { show("routine-form-error", "Choose a running agent."); return; }
      body.target = { address: owner.address, created_ms: owner.created_ms };
    }
    state.working = true;
    $("routine-save").disabled = true;
    updateProposalAvailability();
    show("routine-form-error", "");
    try {
      const path = proposal ? proposal.path : state.draft ? `/api/routines/imported/${state.draft.id}/configure`
        : state.editing ? `/api/routines/${state.item.id}` : "/api/routines";
      const saved = await api(path, body);
      if (proposal) markRoutineProposal(proposal.source, proposal.message, "saved");
      state.working = false;
      await showDetail(saved.id);
      $("routine-back").focus();
    } catch (error) {
      show("routine-form-error", error.message);
    } finally {
      state.working = false;
      $("routine-save").disabled = false;
      updateProposalAvailability();
    }
  });

  async function action(which) {
    const item = state.item;
    if (state.working || !item) return;
    if (which === "test" && !confirm("Send this routine’s task to the agent once now?")) return;
    const revision = state.revision;
    state.working = true;
    for (const action of ["toggle", "test", "edit", "archive"]) $("routine-" + action).disabled = true;
    show("routine-notice", "");
    try {
      if (which === "test") {
        await api(`/api/routines/${item.id}/test`, {});
      } else {
        await api(`/api/routines/${item.id}/state`, which);
      }
    } catch (error) {
      if (revision === state.revision) show("routine-notice", error.message);
    } finally {
      state.working = false;
      if (revision === state.revision) await updateDetail(item.id);
    }
  }

  $("routine-toggle").addEventListener("click", () => action(state.item?.state === "active" ? "pause" : "resume"));
  $("routine-archive").addEventListener("click", () => action("archive"));
  $("routine-test").addEventListener("click", () => action("test"));
  $("routine-move").addEventListener("click", async () => {
    const item = state.item;
    const to = state.destination;
    if (!item || !to || state.working || $("routine-move").disabled) return;
    const rev = state.revision;
    state.working = $("routine-move").disabled = true;
    for (const action of ["toggle", "test", "edit", "archive"]) $("routine-" + action).disabled = true;
    show("routine-notice", "Moving routine…");
    try {
      await api(`/api/routines/${item.id}/move`, {from:{core:item.core,target:item.target},to});
      if (rev !== state.revision) return;
      show("routine-notice", "Moved and paused. Review the new session before resuming.");
    } catch (error) {
      if (rev === state.revision) show("routine-notice", error.message);
    } finally {
      state.working = false;
      if (rev === state.revision) await updateDetail(item.id);
    }
  });
  function clearWebhookKey() {
    $("routine-webhook-secret").value = "";
    $("routine-webhook-secret-box").hidden = true;
  }
  $("routine-webhook-key").addEventListener("click", async () => {
    const item = state.item;
    const rev = state.revision;
    if (!item || state.working || (item.webhook_ready && !confirm("Rotate this key? Senders using the previous key will need to update."))) return;
    state.working = $("routine-webhook-key").disabled = true;
    clearWebhookKey();
    try {
      const result = await api("/api/routines/" + item.id + "/webhook-key", {});
      if (rev !== state.revision) return;
      $("routine-webhook-secret").value = result.key;
      $("routine-webhook-secret-box").hidden = false;
      $("routine-webhook-secret").focus();
      $("routine-webhook-secret").select();
    } catch (error) {
      if (rev === state.revision) show("routine-notice", error.message);
    } finally {
      state.working = false;
      if (rev === state.revision) await updateDetail(item.id);
    }
  });
  setInterval(async () => {
    if ($("routine-dialog").open && state.mode === "imported") updateDraftAvailability();
    if ($("routine-dialog").open && state.proposal) updateProposalAvailability();
    if (!$("routine-dialog").open || state.mode !== "detail" || !state.item || state.working || state.polling) return;
    state.polling = true;
    try { await updateDetail(state.item.id); }
    finally { state.polling = false; }
  }, 2000);
  window.workspaceRoutines = { openReview, openProposal, openById, openImportedById };
})();
