(() => {
  "use strict";

  const dialog = $("agent-drive-dialog");
  const button = $("agent-drive-open");
  const change = $("agent-drive-change");
  const refresh = $("agent-drive-refresh");
  let target = null;
  let working = false;

  function render() {
    const agent = active();
    button.hidden = !app.authorized || !app.online || !live(agent);
    if (dialog.open && (button.hidden || app.core !== target?.core || app.selected !== target?.key)) dialog.close();
  }

  function showStatus(status, note = "") {
    change.hidden = !status.available;
    change.textContent = status.allowed ? "Revoke access" : "Allow read access for one hour";
    change.dataset.allowed = String(status.allowed);
    show("agent-drive-status", note || (status.allowed
      ? `Read access is on · about ${status.minutes_remaining} min remaining.`
      : status.available ? "Read access is off." : "Google Drive isn’t connected or agent access is unavailable. Check Connected files."));
    $("agent-drive-help").hidden = !status.helper;
    $("agent-drive-command").textContent = status.helper ? `${status.helper} drive-list` : "";
    $("agent-drive-read").textContent = status.helper ? `${status.helper} drive-read FILE` : "";
    $("agent-drive-calls").replaceChildren(...status.recent.map((call) => {
      const row = document.createElement("li");
      const time = document.createElement("time");
      time.dateTime = new Date(call.at_ms).toISOString();
      time.textContent = displayDate(call.at_ms);
      const action = call.action === "read" ? "Read file" : "List folder";
      row.append(time, ` · ${action}${call.path ? ": " + call.path : ""} · ${call.succeeded ? "Completed" : "Refused or failed"}`);
      return row;
    }));
    show("agent-drive-empty", status.recent.length ? "" : "No recent requests for this session.");
  }

  button.addEventListener("click", async () => {
    const agent = active();
    if (dialog.open || working || !app.authorized || !app.online || !live(agent)) return;
    const core = app.core;
    const key = idOf(agent);
    const request = target = {core, key, path:`/api/agents/${key}/drive-access`};
    $("agent-drive-target").textContent = window.agentProfiles.current()?.name || title(agent);
    change.hidden = true;
    $("agent-drive-help").hidden = true;
    $("agent-drive-calls").replaceChildren();
    show("agent-drive-empty", "");
    show("agent-drive-status", "Checking access…");
    dialog.showModal();
    await load(request);
  });

  async function load(request) {
    refresh.disabled = change.disabled = true;
    try {
      const status = await api(`${request.path}?${new URLSearchParams({core:request.core})}`);
      if (target === request && dialog.open) showStatus(status);
    } catch (error) {
      if (target === request && dialog.open) show("agent-drive-status", error.message);
    } finally { if (target === request) refresh.disabled = change.disabled = false; }
  }

  refresh.addEventListener("click", () => {
    if (target && !working) void load(target);
  });

  change.addEventListener("click", async () => {
    if (!target || working || change.hidden) return;
    const request = target;
    const allowed = change.dataset.allowed !== "true";
    working = change.disabled = refresh.disabled = true;
    show("agent-drive-status", allowed ? "Granting access…" : "Revoking access…");
    try {
      const status = await api(request.path, {core:request.core, allowed});
      if (target === request && dialog.open) showStatus(status, status.allowed
        ? "Read access granted for one hour." : "Read access is off.");
    } catch (error) {
      if (target === request && dialog.open) show("agent-drive-status", error.message);
    } finally { working = change.disabled = refresh.disabled = false; }
  });

  $("agent-drive-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { if (!dialog.open) target = null; });
  window.swarmDriveAccess = {render};
})();
