(() => {
  "use strict";

  const dialog = document.createElement("dialog");
  dialog.id = "group-handoff-dialog";
  dialog.setAttribute("aria-labelledby", "group-handoff-heading");
  dialog.innerHTML = `
    <div class="details-header"><h2 id="group-handoff-heading">Review group handoff</h2><button type="button" id="group-handoff-close" class="icon" aria-label="Close group handoff">×</button></div>
    <p id="group-handoff-status" role="status" hidden></p>
    <form id="group-handoff-form" hidden>
      <label for="group-handoff-recipient">Send to</label><input id="group-handoff-recipient" readonly>
      <label for="group-handoff-task">Follow-up task</label><textarea id="group-handoff-task" rows="5" maxlength="4096" required></textarea>
      <details open><summary>Original group task</summary><p id="group-handoff-excerpt"></p></details>
      <p class="subtle">This sends only to the agent shown above when you choose Send handoff.</p>
      <p id="group-handoff-error" class="error" role="alert" hidden></p>
      <button type="button" id="group-handoff-dismiss">Dismiss suggestion</button>
      <div class="dialog-actions"><button type="button" id="group-handoff-cancel">Cancel</button><button type="submit" id="group-handoff-send" class="primary">Send handoff</button></div>
    </form>`;
  document.body.append(dialog);
  let current = null;
  let sequence = 0;
  let working = false;
  const form = $("group-handoff-form");
  const field = $("group-handoff-task");

  function clear() {
    current = null;
    field.value = $("group-handoff-recipient").value = $("group-handoff-excerpt").textContent = "";
    form.hidden = true;
  }

  function label(button, state) {
    button.disabled = state === "dismissed";
    button.textContent = state === "approved" ? "Handoff approved"
      : state === "dismissed" ? "Handoff dismissed" : "Review handoff";
  }

  function mark(path, state, group, message) {
    for (const button of document.querySelectorAll("[data-group-handoff]")) {
      if (button.dataset.groupHandoff === path) label(button, state);
    }
    window.groupWorkspace?.updateHandoff(group, message, state);
  }

  function update() {
    if (!app.authorized && dialog.open) {
      ++sequence;
      clear();
      dialog.close();
      return;
    }
    if (!current) return;
    const proposal = current.proposal;
    const liveRecipient = app.online && app.core === proposal.core
      && app.agents.some((agent) => idOf(agent) === idOf(proposal.target) && live(agent));
    $("group-handoff-send").disabled = working || !proposal.eligible || !liveRecipient;
    $("group-handoff-dismiss").disabled = $("group-handoff-close").disabled = $("group-handoff-cancel").disabled = field.disabled = working;
    if (!working) {
      const message = !proposal.eligible ? "The proposing agent or recipient is no longer in this group."
        : !liveRecipient ? "The recipient isn’t online. You can review or dismiss the suggestion."
        : `${proposal.author} suggested this follow-up.`;
      if ($("group-handoff-status").textContent !== message) show("group-handoff-status", message);
    }
  }

  async function open(group, message) {
    if (dialog.open || !app.authorized) return;
    clear();
    const requested = ++sequence;
    const token = app.token;
    const visible = () => dialog.open && sequence === requested && app.authorized && app.token === token;
    const path = `/api/groups/${group}/handoffs/${message}`;
    show("group-handoff-status", "Loading handoff…");
    show("group-handoff-error", "");
    dialog.showModal();
    try {
      const proposal = await api(path);
      if (!visible()) return;
      if (proposal.approved) {
        mark(path, "approved", group, message);
        show("group-handoff-status", "This handoff was approved. Check its delivery in the group.");
        return;
      }
      if (proposal.task == null) {
        mark(path, "dismissed", group, message);
        show("group-handoff-status", "This handoff was dismissed.");
        return;
      }
      current = {path, group, message, visible, proposal};
      $("group-handoff-recipient").value = proposal.recipient;
      $("group-handoff-excerpt").textContent = proposal.excerpt;
      field.value = proposal.task;
      form.hidden = false;
      update();
      field.focus();
    } catch (error) {
      if (visible()) show("group-handoff-status", error.message);
    }
  }

  async function settle(dismiss) {
    const target = current;
    if (!target?.visible() || working || (!dismiss && $("group-handoff-send").disabled)) return;
    const task = field.value;
    if (!dismiss && (!taskOk(task) || new TextEncoder().encode(task).length > 4096)) {
      show("group-handoff-error", "Enter a follow-up up to 4 KiB.");
      field.focus();
      return;
    }
    working = true;
    update();
    show("group-handoff-error", "");
    show("group-handoff-status", dismiss ? "Dismissing suggestion…" : "Queuing the reviewed follow-up…");
    try {
      await api(target.path + (dismiss ? "/dismiss" : "/approve"), dismiss ? {} : {revision:target.proposal.revision, task});
      if (!target.visible()) return;
      mark(target.path, dismiss ? "dismissed" : "approved", target.group, target.message);
      clear();
      show("group-handoff-status", dismiss ? "Handoff dismissed." : "Handoff queued. Check delivery in the group.");
    } catch (error) {
      if (target.visible()) show("group-handoff-error", error.message);
    } finally {
      working = false;
      $("group-handoff-close").disabled = false;
      update();
      if (target.visible() && form.hidden) $("group-handoff-close").focus();
    }
  }

  function close() { if (!working) dialog.close(); }
  $("group-handoff-close").addEventListener("click", close);
  $("group-handoff-cancel").addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => { if (working) event.preventDefault(); });
  dialog.addEventListener("close", () => { if (!dialog.open) { ++sequence; clear(); } });
  form.addEventListener("submit", (event) => { event.preventDefault(); void settle(false); });
  $("group-handoff-dismiss").addEventListener("click", () => void settle(true));

  window.workspaceGroupHandoffs = { label, open, update };
})();
