(() => {
  "use strict";

  const dialog = document.createElement("dialog");
  dialog.id = "memory-proposal-dialog";
  dialog.setAttribute("aria-labelledby", "memory-proposal-heading");
  dialog.innerHTML = `
    <div class="details-header"><h2 id="memory-proposal-heading">Review memory suggestion</h2><button type="button" id="memory-proposal-close" class="icon" aria-label="Close memory suggestion">×</button></div>
    <p id="memory-proposal-status" role="status"></p>
    <form id="memory-proposal-form" hidden>
      <label for="memory-proposal-text">Memory to save</label>
      <textarea id="memory-proposal-text" rows="3" maxlength="512" required aria-describedby="memory-proposal-help"></textarea>
      <p id="memory-proposal-help" class="subtle"></p>
      <p id="memory-proposal-error" class="error" role="alert" hidden></p>
      <button type="button" id="memory-proposal-dismiss">Dismiss suggestion</button>
      <div class="dialog-actions"><button type="button" id="memory-proposal-cancel">Cancel</button><button type="submit" id="memory-proposal-save" class="primary">Append to standing instructions</button></div>
    </form>`;
  document.body.append(dialog);

  let target = null;
  let revision = 0;
  let saving = false;
  const field = $("memory-proposal-text");
  const form = $("memory-proposal-form");
  const save = $("memory-proposal-save");
  const dismiss = $("memory-proposal-dismiss");
  const bytes = new TextEncoder();

  function label(button, state) {
    button.disabled = state === "dismissed";
    button.textContent = state === "saved" ? "Memory saved"
      : state === "dismissed" ? "Memory suggestion dismissed" : "Review memory suggestion";
  }

  function mark(path, state) {
    const activePath = app.selected && app.historyCore
      ? "/api/history/" + encodeURIComponent(app.historyCore) + "/" + app.selected : null;
    const split = path.lastIndexOf("/memory-proposals/");
    if (path.slice(0, split) === activePath) {
      const entry = app.history.entries.find((item) => item.id === Number(path.slice(split + "/memory-proposals/".length)));
      if (entry) entry.memory_proposal = state;
    }
    for (const button of document.querySelectorAll("[data-memory-proposal]")) {
      if (button.dataset.memoryProposal === path) label(button, state);
    }
  }

  async function open(path) {
    if (dialog.open || !app.authorized) return;
    const requested = ++revision;
    const token = app.token;
    target = null;
    field.value = "";
    form.hidden = true;
    $("memory-proposal-heading").textContent = "Review memory suggestion";
    show("memory-proposal-status", "Loading memory suggestion…");
    show("memory-proposal-error", "");
    dialog.showModal();
    try {
      const item = await api(path);
      if (!dialog.open || requested !== revision || token !== app.token || !app.authorized) return;
      if (item.state === "saved") {
        show("memory-proposal-status", `This memory was saved to ${item.profile?.name || "the agent’s"} standing instructions.`);
        return;
      }
      if (item.state === "dismissed") {
        show("memory-proposal-status", "This memory suggestion was dismissed.");
        return;
      }
      target = {path, profile: item.profile};
      field.value = item.text;
      show("memory-proposal-status", item.profile
        ? `Review what to remember for ${item.profile.name}. Saving applies to future sessions.`
        : "This suggestion is waiting for a saved agent profile. You can review or dismiss it now.");
      $("memory-proposal-help").textContent = item.profile
        ? `Use one line up to 512 bytes. ${item.profile.remaining_bytes} bytes are available in the profile’s standing instructions. Keep credentials out of suggestions.`
        : "Keep credentials out of suggestions.";
      form.hidden = false;
      update();
      field.focus();
    } catch (error) {
      if (dialog.open && requested === revision) show("memory-proposal-status", error.message);
    }
  }

  function close() { if (!saving) dialog.close(); }
  function lockIfNeeded() {
    if (app.authorized || !dialog.open) return;
    ++revision;
    target = null;
    field.value = "";
    form.hidden = true;
    dialog.close();
  }
  $("memory-proposal-close").addEventListener("click", close);
  $("memory-proposal-cancel").addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++revision;
    target = null;
    field.value = "";
  });

  function update() {
    save.disabled = saving || !target?.profile;
    dismiss.disabled = field.disabled = saving;
    $("memory-proposal-close").disabled = $("memory-proposal-cancel").disabled = saving;
  }

  async function submit(dismissing) {
    if (saving || !target || !app.authorized || (!dismissing && !target.profile)) return;
    const text = field.value;
    if (!dismissing && (!text.trim() || bytes.encode(text).length > 512 || /\p{Cc}/u.test(text))) {
      show("memory-proposal-error", "Enter one line of plain text up to 512 bytes.");
      field.focus();
      return;
    }
    const path = target.path;
    const profile = target.profile;
    saving = true;
    update();
    show("memory-proposal-error", "");
    try {
      if (dismissing) {
        await api(path + "/dismiss", {});
        mark(path, "dismissed");
        show("memory-proposal-status", "Memory suggestion dismissed.");
      } else {
        await api(path, {profile_id: profile.id, text});
        mark(path, "saved");
        show("memory-proposal-status", `Memory saved to ${profile.name}’s standing instructions.`);
        await window.agentProfiles.load().catch(() => {});
        if (app.authorized) renderState();
      }
      field.value = "";
      form.hidden = true;
      target = null;
    } catch (error) {
      show("memory-proposal-error", error.message);
      field.focus();
    } finally {
      saving = false;
      update();
      if (form.hidden) $("memory-proposal-close").focus();
    }
  }
  form.addEventListener("submit", (event) => { event.preventDefault(); void submit(false); });
  dismiss.addEventListener("click", () => void submit(true));

  window.workspaceMemoryProposals = { label, lockIfNeeded, open };
})();
