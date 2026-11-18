(() => {
  "use strict";
  const dialog = $("vault-dialog");
  const form = $("vault-form");
  let revision = 0, editing = null, renaming = false, busy = false;
  const current = (requested) => dialog.open && revision === requested;

  async function list(message = "") {
    const requested = ++revision;
    editing = null;
    $("vault-heading").textContent = "Vault";
    $("vault-value").value = "";
    form.hidden = true;
    $("vault-list-view").hidden = false;
    $("vault-list").replaceChildren();
    $("vault-missing").replaceChildren();
    $("vault-missing-view").hidden = true;
    $("vault-new").disabled = true;
    show("vault-status", "Loading vault…");
    try {
      const {configured, entries, bindings = []} = await api("/api/vault");
      if (!current(requested)) return;
      $("vault-new").disabled = !configured;
      show("vault-status", !configured ? "A vault key hasn’t been configured on this workspace host."
        : message || (entries.length ? "" : "No secrets saved."));
      $("vault-list").replaceChildren(...entries.map((entry) => {
        const row = document.createElement("li");
        const name = document.createElement("strong");
        name.textContent = entry.name;
        const usedBy = bindings.find((binding) => binding.name.toLowerCase() === entry.name.toLowerCase())?.used_by || [];
        const actions = document.createElement("div");
        actions.className = "routine-actions";
        for (const [label, action] of [["Replace value", () => edit(entry)], ["Rename", () => edit(entry, "", true)], ["Remove", () => remove(entry, usedBy)]]) {
          const button = document.createElement("button");
          button.type = "button";
          button.textContent = label;
          button.setAttribute("aria-label", label + " for " + entry.name);
          button.addEventListener("click", action);
          actions.append(button);
        }
        row.append(name);
        if (usedBy.length) {
          const usage = document.createElement("small");
          usage.textContent = "Used by " + usedBy.join(" and ");
          row.append(usage);
        }
        row.append(actions);
        return row;
      }));
      const missing = bindings.filter((binding) => !binding.present);
      $("vault-missing-view").hidden = !missing.length;
      $("vault-missing").replaceChildren(...missing.map((binding) => {
        const row = document.createElement("li");
        const button = document.createElement("button");
        const hint = document.createElement("small");
        button.type = "button";
        button.textContent = "Add " + binding.name;
        hint.textContent = "Needed by " + binding.used_by.join(" and ");
        button.append(hint);
        button.addEventListener("click", () => edit(null, binding.name));
        row.append(button);
        return row;
      }));
    } catch (error) {
      if (current(requested)) show("vault-status", error.message);
    }
  }

  function edit(entry = null, binding = "", rename = false) {
    if (busy) return;
    ++revision;
    editing = entry;
    renaming = rename;
    $("vault-heading").textContent = rename ? "Rename secret" : entry ? "Replace secret" : "Add secret";
    $("vault-name").value = entry?.name || binding;
    $("vault-name").readOnly = !rename && Boolean(entry || binding);
    $("vault-value").value = "";
    $("vault-value").required = !rename;
    $("vault-value").hidden = $("vault-value-label").hidden = rename;
    $("vault-save").textContent = rename ? "Rename" : entry ? "Replace value" : "Save secret";
    $("vault-list-view").hidden = true;
    form.hidden = false;
    show("vault-status", "");
    $(!rename && (entry || binding) ? "vault-value" : "vault-name").focus();
  }

  async function remove(entry, usedBy) {
    const impact = usedBy.length ? " This will stop " + usedBy.join(" and ") + " from using the secret." : "";
    if (busy || !confirm("Remove “" + entry.name + "” from the vault?" + impact)) return;
    const requested = revision;
    busy = true;
    try {
      await api("/api/vault/" + entry.id + "/remove", {revision:entry.revision});
      if (current(requested)) await list("Secret removed.");
    } catch (error) {
      if (current(requested)) show("vault-status", error.message);
    } finally { busy = false; }
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (busy) return;
    const requested = revision;
    const entry = editing;
    const name = $("vault-name").value;
    const value = $("vault-value").value;
    const operation = renaming ? "rename" : "replace";
    const body = entry ? {revision:entry.revision, ...(renaming ? {name} : {value})} : {name,value};
    $("vault-value").value = "";
    busy = $("vault-save").disabled = true;
    show("vault-status", "Saving secret…");
    try {
      await api(entry ? "/api/vault/" + entry.id + "/" + operation : "/api/vault", body);
      if (current(requested)) await list(renaming ? "Secret renamed." : "Secret saved.");
    } catch (error) {
      if (current(requested)) { show("vault-status", error.message); $(renaming ? "vault-name" : "vault-value").focus(); }
    } finally {
      busy = $("vault-save").disabled = false;
    }
  });

  $("vault-open").addEventListener("click", () => { dialog.showModal(); void list(); });
  $("vault-close").addEventListener("click", () => dialog.close());
  $("vault-new").addEventListener("click", () => edit());
  $("vault-cancel").addEventListener("click", () => { if (!busy) void list(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++revision;
    $("vault-value").value = "";
    $("vault-list").replaceChildren();
  });
})();

(() => {
  "use strict";
  const dialog = $("vault-request-dialog");
  const input = $("vault-request-value");
  const save = $("vault-request-save");
  const cancel = $("vault-request-cancel");
  let active = null, saving = false, polling = false;
  let unsupportedToken = null;

  async function poll() {
    if (!app.authorized) {
      input.value = "";
      if (dialog.open) dialog.close();
      return;
    }
    if (polling || saving || unsupportedToken === app.token) return;
    const token = app.token;
    polling = true;
    try {
      const pending = await api("/api/vault/requests");
      if (!app.authorized || token !== app.token || saving) return;
      if (dialog.open) {
        if (!pending.some(({id}) => id === active?.id)) {
          input.value = "";
          dialog.close();
        }
        return;
      }
      if (!pending.length || document.querySelector("dialog[open]")) return;
      active = pending[0];
      $("vault-request-bot").textContent = active.bot + " requests access for one command.";
      $("vault-request-name").textContent = active.name;
      $("vault-request-label").textContent = active.label;
      $("vault-request-description").textContent = active.description;
      input.value = "";
      input.hidden = $("vault-request-value-label").hidden = !active.needs_value;
      input.required = active.needs_value;
      save.textContent = active.needs_value ? "Save" : "Allow once";
      show("vault-request-status", "");
      dialog.showModal();
      (active.needs_value ? input : cancel).focus();
    } catch (error) {
      if (error.status === 404) unsupportedToken = token;
    } finally {
      polling = false;
    }
  }

  async function decide(action) {
    if (saving || !active || !app.authorized) return;
    const request = active;
    const token = app.token;
    const body = {action};
    if (action === "save" && request.needs_value) body.value = input.value;
    input.value = "";
    saving = save.disabled = cancel.disabled = true;
    show("vault-request-status", action === "save" ? "Saving…" : "Cancelling…");
    try {
      await api("/api/vault/requests/" + encodeURIComponent(request.id), body);
      dialog.close();
    } catch (error) {
      if (token === app.token && dialog.open) {
        show("vault-request-status", error.message);
        if (request.needs_value) input.focus();
      }
    } finally {
      saving = save.disabled = cancel.disabled = false;
    }
  }

  $("vault-request-form").addEventListener("submit", (event) => {
    event.preventDefault();
    void decide("save");
  });
  cancel.addEventListener("click", () => void decide("cancel"));
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    void decide("cancel");
  });
  dialog.addEventListener("close", () => {
    if (!dialog.open) {
      input.value = "";
      active = null;
    }
  });
  setInterval(poll, 2000);
  void poll();
})();
