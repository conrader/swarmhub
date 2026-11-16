(() => {
  "use strict";
  const open = $("agent-github-access-open");
  if (!open) return;
  const dialog = document.createElement("dialog");
  dialog.id = "agent-github-access-dialog";
  dialog.setAttribute("aria-labelledby", "agent-github-access-heading");
  dialog.innerHTML = `<div class="details-header"><h2 id="agent-github-access-heading">GitHub read access</h2><button type="button" id="agent-github-access-close">Close</button></div>
    <p id="agent-github-access-target" class="subtle"></p>
    <p>Allow this session to read excerpts from open issues and pull requests in the configured repository. The GitHub token stays with the workspace.</p>
    <p class="subtle">This is a workspace grant, not isolation between processes running under the same operating-system account.</p>
    <p id="agent-github-access-status" role="status"></p>
    <section id="agent-github-access-help" hidden aria-label="Agent commands">
      <p>From this agent’s terminal:</p><p><code id="agent-github-access-issue"></code><br><code id="agent-github-access-pr"></code></p>
    </section>
    <h3>Recent requests</h3><p id="agent-github-access-empty" class="subtle"></p>
    <ul id="agent-github-access-calls" class="library-items"></ul>
    <div class="dialog-actions compose-tools"><button type="button" id="agent-github-access-refresh">Refresh</button><button type="button" id="agent-github-access-change" class="primary" hidden></button></div>`;
  document.body.append(dialog);
  const get = (name) => $("agent-github-access-" + name);
  const change = get("change"), refresh = get("refresh");
  let current = null;
  let working = false;

  function target() {
    const agent = active();
    return app.authorized && app.online && live(agent) && window.workspaceGitHubProject?.repository?.()
      ? {key:idOf(agent), core:app.core, token:app.token, name:window.agentProfiles.current()?.name || title(agent)} : null;
  }
  function held(request) {
    if (!request) return false;
    const active = target();
    return dialog.open && current === request && active?.key === request.key && active.core === request.core && active.token === request.token;
  }
  function clear() {
    current = null;
    change.hidden = get("help").hidden = true;
    for (const name of ["status", "target", "empty", "issue", "pr"]) get(name).textContent = "";
    get("calls").replaceChildren();
  }
  function close() { clear(); if (dialog.open) dialog.close(); }
  function render() {
    open.hidden = !target();
    if (dialog.open && !held(current)) close();
  }
  function status(result) {
    const allowed = result.minutes_remaining !== null;
    current.allowed = allowed;
    change.hidden = !result.available;
    change.textContent = allowed ? "Revoke access" : "Allow read access for one hour";
    get("target").textContent = `${current.name} · ${result.repository}`;
    get("status").textContent = allowed ? `Read access is on · about ${result.minutes_remaining} min remaining.`
      : result.available ? "Read access is off." : "GitHub access is unavailable. Check the repository and Vault configuration.";
    get("help").hidden = !result.helper;
    get("issue").textContent = result.helper ? `${result.helper} github-read issue NUMBER` : "";
    get("pr").textContent = result.helper ? `${result.helper} github-read pr NUMBER` : "";
    get("empty").textContent = result.recent.length ? "" : "No recent requests for this session.";
    get("calls").replaceChildren(...result.recent.map((call) => {
      const row = document.createElement("li");
      const label = call.kind === "issue" ? "Issue" : "Pull request";
      row.textContent = `${label} #${call.number} · ${call.succeeded ? "Read" : "Failed or refused"} · ${displayDate(call.at_ms)}`;
      return row;
    }));
  }
  async function request(choice = null) {
    const selected = current;
    if (!selected || !held(selected) || working) return;
    const path = `/api/agents/${selected.key}/github-access`;
    working = change.disabled = refresh.disabled = true;
    get("status").textContent = choice === null ? "Checking access…" : choice ? "Granting access…" : "Revoking access…";
    try {
      const result = await (choice === null ? api(`${path}?${new URLSearchParams({core:selected.core})}`)
        : api(path, {core:selected.core,allowed:choice}));
      if (held(selected)) status(result);
    } catch (error) {
      if (held(selected)) get("status").textContent = error.message;
    } finally { working = change.disabled = refresh.disabled = false; }
  }
  open.addEventListener("click", () => {
    const selected = target();
    if (!selected || dialog.open || working) return;
    clear();
    current = selected;
    get("target").textContent = selected.name;
    dialog.showModal();
    void request();
  });
  get("close").addEventListener("click", close);
  dialog.addEventListener("close", () => { if (!dialog.open) clear(); });
  refresh.addEventListener("click", () => void request());
  change.addEventListener("click", () => { if (current && !change.hidden) void request(!current.allowed); });
  window.swarmGitHubAccess = {render};
  render();
})();
