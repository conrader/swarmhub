(() => {
  "use strict";
  const dialog = $("vault-dialog");
  const form = $("vault-form");
  let revision = 0, editing = null, busy = false;
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
        for (const [label, action] of [["Replace value", () => edit(entry)], ["Remove", () => remove(entry, usedBy)]]) {
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

  function edit(entry = null, binding = "") {
    if (busy) return;
    ++revision;
    editing = entry;
    $("vault-heading").textContent = entry ? "Replace secret" : "Add secret";
    $("vault-name").value = entry?.name || binding;
    $("vault-name").readOnly = Boolean(entry || binding);
    $("vault-value").value = "";
    $("vault-save").textContent = entry ? "Replace value" : "Save secret";
    $("vault-list-view").hidden = true;
    form.hidden = false;
    show("vault-status", "");
    $(entry || binding ? "vault-value" : "vault-name").focus();
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
    const value = $("vault-value").value;
    const body = entry ? {value,revision:entry.revision} : {name:$("vault-name").value,value};
    $("vault-value").value = "";
    busy = $("vault-save").disabled = true;
    show("vault-status", "Saving secret…");
    try {
      await api(entry ? "/api/vault/" + entry.id + "/replace" : "/api/vault", body);
      if (current(requested)) await list("Secret saved.");
    } catch (error) {
      if (current(requested)) { show("vault-status", error.message); $("vault-value").focus(); }
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
