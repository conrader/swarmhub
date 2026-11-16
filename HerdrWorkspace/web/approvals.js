(() => {
  "use strict";

  const state = { pending: [], history: [], rules: [], active: null, polling: false, working: false, signature: null };
  const dialog = $("approval-dialog");
  const status = { approved: "Allow once sent", denied: "Denial sent", terminal: "Returned to the agent" };

  function refreshBadge() {
    const count = $("approval-count");
    count.hidden = !state.pending.length;
    const text = String(state.pending.length);
    if (count.textContent !== text) count.textContent = text;
    if (state.pending.length) count.setAttribute("aria-label", `${text} awaiting review`);
    else count.removeAttribute("aria-label");
  }

  async function load() {
    const token = app.token;
    try {
      const result = await api("/api/approvals");
      if (!app.authorized || token !== app.token) return;
      state.pending = result.pending;
      state.history = result.history;
      state.rules = result.read_rules;
      refreshBadge();
      if (dialog.open) render();
    } catch (error) {
      if (dialog.open) show("approval-notice", error.message);
    } finally {
      state.polling = null;
    }
  }

  function poll() {
    if (!app.authorized) return;
    return state.polling ||= load();
  }

  function item(title, summary) {
    const strong = document.createElement("strong");
    strong.textContent = title;
    const small = document.createElement("small");
    small.textContent = summary;
    return [strong, small];
  }

  function listView() {
    state.active = null;
    $("approval-input").textContent = "";
    $("approval-path").textContent = "";
    state.signature = null;
    $("approval-detail").hidden = true;
    $("approval-remember-options").hidden = true;
    $("approval-list-view").hidden = false;
    render();
  }

  // Render potentially invisible direction/formatting characters visibly in the
  // preview so they cannot disguise parts of the actual command or arguments.
  function visible(value) {
    return value.replace(/[\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/g, (char) =>
      "\\u" + char.charCodeAt(0).toString(16).padStart(4, "0"));
  }

  function details(request) {
    const resources = request.provider === "OpenCode";
    const instruction = resources ? "Review the action and resources before deciding." : "Review the exact arguments before deciding.";
    state.active = { id: request.id, instruction };
    $("approval-list-view").hidden = true;
    $("approval-detail").hidden = false;
    $("approval-action").textContent = `${request.agent} requests ${request.tool}`;
    $("approval-path").textContent = [request.provider, visible(request.cwd)].filter(Boolean).join(" · ");
    $("approval-input").textContent = visible(resources ? JSON.stringify(JSON.parse(request.arguments), null, 2) : request.arguments);
    $("approval-remember-options").hidden = !request.can_remember_read;
    show("approval-notice", instruction);
    $("approval-back").focus();
    render();
  }

  function render() {
    if (state.active) {
      const waiting = state.pending.some(({id}) => id === state.active.id);
      for (const button of ["allow", "deny", "terminal", "remember"]) $("approval-" + button).disabled = !waiting || state.working;
      if (!waiting && !state.working && $("approval-notice").textContent === state.active.instruction) {
        $("approval-input").textContent = "";
        $("approval-path").textContent = "";
        show("approval-notice", "This request is no longer waiting. Check the agent’s terminal.");
      }
      return;
    }
    const signature = JSON.stringify([state.pending.map(({id}) => id), state.history, state.rules]);
    if (state.signature === signature) return;
    state.signature = signature;
    $("approval-list").replaceChildren(...state.pending.map((request) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.append(...item(`${request.agent} · ${request.tool}`, `${request.provider} · Waiting until ${displayDate(request.expires_ms)}`));
      button.addEventListener("click", () => details(request));
      row.append(button);
      return row;
    }));
    $("approval-history").replaceChildren(...state.history.map((record) => {
      const row = document.createElement("li");
      const outcome = record.unconfirmed ? "Decision not confirmed · check terminal"
        : record.automatic ? "Allowed by read rule" : status[record.state] || record.state;
      row.append(...item(`${record.agent} · ${record.tool}`,
        `${record.provider} · ${outcome} · ${displayDate(record.resolved_ms ?? record.requested_ms)}`));
      return row;
    }));
    $("approval-read-rules").replaceChildren(...state.rules.map((rule) => {
      const row = document.createElement("li");
      row.append(...item(rule.agent, `${rule.path} · Until ${displayDate(rule.expires_ms)}`));
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = "Revoke read rule";
      button.addEventListener("click", async () => {
        if (!app.authorized || button.disabled) return;
        button.disabled = true;
        try {
          await api(`/api/approval-rules/${rule.id}/revoke`, {});
          show("approval-notice", "Read rule revoked.");
          await poll();
        } catch (error) { if (dialog.open) show("approval-notice", error.message); }
        finally { button.disabled = false; }
      });
      row.append(button);
      return row;
    }));
    for (const [id, text] of [["approval-list", "No requests are waiting."], ["approval-history", "No decisions recorded."], ["approval-read-rules","No temporary read rules."]]) {
      if ($(id).children.length) continue;
      const empty = document.createElement("li");
      empty.textContent = text;
      $(id).append(empty);
    }
  }

  async function decide(choice) {
    const request = state.active;
    if (!request || state.working) return;
    state.working = true;
    render();
    try {
      await api(`/api/approvals/${request.id}`, choice);
      state.pending = state.pending.filter(({id}) => id !== request.id);
      refreshBadge();
      listView();
      show("approval-notice", choice === "terminal" ? "Terminal review requested. Open the agent’s terminal for its prompt."
        : choice === "remember_read" ? "Decision submitted. The rule appears after OpenCode confirms." : "Decision submitted.");
      $("approval-input").textContent = "";
      $("approval-path").textContent = "";
      await poll();
    } catch (error) {
      show("approval-notice", error.message);
      await poll();
    } finally {
      state.working = false;
      render();
    }
  }

  async function open(id) {
    show("approval-notice", "");
    dialog.showModal();
    listView();
    await poll();
    if (id === undefined || !dialog.open) return;
    const request = state.pending.find((row) => row.id === id);
    if (request) details(request);
    else show("approval-notice", "This request is no longer waiting for a decision.");
  }
  function lockIfNeeded() {
    if (app.authorized) return;
    if (dialog.open) dialog.close();
    state.pending = state.history = state.rules = [];
    state.active = null;
    refreshBadge();
    $("approval-input").textContent = $("approval-path").textContent = $("approval-action").textContent = "";
    for (const id of ["approval-list", "approval-history", "approval-read-rules"]) $(id).replaceChildren();
  }
  window.approvalInbox = { open, lockIfNeeded };
  $("approvals-open").addEventListener("click", () => void open());
  $("approval-close").addEventListener("click", () => { if (!state.working) dialog.close(); });
  $("approval-back").addEventListener("click", () => { show("approval-notice", ""); listView(); });
  $("approval-allow").addEventListener("click", () => decide("approve"));
  $("approval-remember").addEventListener("click", () => decide("remember_read"));
  $("approval-deny").addEventListener("click", () => decide("deny"));
  $("approval-terminal").addEventListener("click", () => decide("terminal"));
  dialog.addEventListener("cancel", (event) => { if (state.working) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    state.active = null;
    $("approval-input").textContent = "";
    $("approval-path").textContent = "";
  });
  setInterval(poll, 1800);
})();
