(() => {
  "use strict";
  const get = (id) => document.getElementById("profile-template-" + id);
  const importButton = get("import");
  const exportButton = get("export");
  if (!importButton || !exportButton) return;

  const dialog = document.createElement("dialog");
  dialog.id = "profile-template-dialog";
  dialog.setAttribute("aria-labelledby", "profile-template-heading");
  dialog.innerHTML = `<form id="profile-template-form">
    <div class="details-header"><h2 id="profile-template-heading"></h2><button id="profile-template-close" class="icon" type="button" aria-label="Close agent template">×</button></div>
    <p id="profile-template-help" class="subtle"></p>
    <p id="profile-template-status" role="status" hidden></p>
    <p id="profile-template-error" class="error" role="alert" tabindex="-1" hidden></p>
    <button id="profile-template-choose" type="button">Choose template file</button>
    <input id="profile-template-file" type="file" accept=".json,application/json" hidden>
    <div id="profile-template-fields" hidden>
      <label for="profile-template-name">Display name</label><input id="profile-template-name" required disabled>
      <label for="profile-template-subtitle">Label</label><input id="profile-template-subtitle">
      <label for="profile-template-avatar">Avatar</label><select id="profile-template-avatar"><option value="initial">Initial</option><option value="spark">Spark</option><option value="layers">Layers</option><option value="target">Target</option><option value="terminal">Terminal</option></select>
      <label for="profile-template-instructions">Standing instructions</label><textarea id="profile-template-instructions" rows="5" aria-describedby="profile-template-instructions-help"></textarea>
      <p class="subtle" id="profile-template-instructions-help"></p>
    </div>
    <div class="dialog-actions"><button id="profile-template-save" class="primary" type="submit" disabled></button></div>
  </form>`;
  document.body.append(dialog);
  const form = get("form");
  const file = get("file");
  const choose = get("choose");
  const save = get("save");
  const fields = ["name", "subtitle", "avatar", "instructions"];
  const format = "swarmhub-agent-template/v1";
  let mode = "";
  let ready = false;
  let busy = false;
  let committing = false;
  let sequence = 0;

  function message(id, text) {
    show("profile-template-" + id, text);
    if (id === "error" && text) get(id).focus();
  }

  function update() {
    const importing = mode === "import";
    get("fields").hidden = !ready;
    for (const field of fields) get(field).disabled = !ready || busy;
    choose.hidden = !importing;
    choose.disabled = busy;
    choose.textContent = ready ? "Choose another file" : "Choose template file";
    save.disabled = !ready || busy;
    save.textContent = importing ? (busy && ready ? "Creating…" : "Create agent") : "Download template";
    get("close").disabled = committing;
  }

  function reset() {
    ++sequence;
    busy = false;
    committing = false;
    ready = false;
    form.reset();
    update();
    message("error", "");
    message("status", "");
  }

  function render(profile) {
    importButton.disabled = exportButton.disabled = !app.authorized;
    exportButton.hidden = !profile;
    if (!app.authorized && dialog.open) {
      reset();
      dialog.close();
    }
  }

  function open(next) {
    if (!app.authorized || dialog.open) return false;
    mode = next;
    reset();
    const importing = mode === "import";
    get("heading").textContent = importing ? "Import agent template" : "Download agent template";
    get("help").textContent = importing ? "Review the template before creating a new agent profile. You can choose a runtime when you’re ready to start the agent."
      : "Review the settings to include in the file. You can edit or clear any text here without changing the saved profile.";
    get("instructions-help").textContent = importing ? "These instructions are saved to the profile. They’re only sent if you choose to use them when starting a session."
      : "Anyone with the file can read these instructions. Remove any private information before sharing it.";
    dialog.showModal();
    return true;
  }

  function populate(template) {
    for (const field of fields) get(field).value = template[field];
    ready = true;
    busy = false;
    update();
    get("name").focus();
  }

  function current(attempt, token) {
    return attempt === sequence && dialog.open && app.authorized && app.token === token;
  }

  async function preview(contents, token) {
    const response = await fetch("/api/profile-templates/preview", {
      method: "POST", headers: {Authorization: "Bearer " + token, "Content-Type": "application/json"}, body: contents,
    });
    const result = await response.json().catch(() => null);
    if (!response.ok || !result) throw new Error(result?.error || "Could not read the agent template.");
    return result;
  }

  importButton.addEventListener("click", () => { if (open("import")) choose.focus(); });
  exportButton.addEventListener("click", async () => {
    const profile = window.agentProfiles.current();
    if (!profile || !open("export")) return;
    const attempt = sequence, token = app.token;
    message("status", "Loading saved profile…");
    try {
      const template = await api(`/api/profiles/${profile.id}/agent-template`);
      if (!current(attempt, token)) return;
      populate(template);
      message("status", "");
    } catch (error) {
      if (!current(attempt, token)) return;
      message("status", "");
      message("error", error.message);
    }
  });
  get("close").addEventListener("click", () => { if (!committing) dialog.close(); });
  dialog.addEventListener("cancel", (event) => { if (committing) event.preventDefault(); });
  dialog.addEventListener("close", () => { if (!dialog.open) reset(); });
  choose.addEventListener("click", () => file.click());
  file.addEventListener("change", async () => {
    const selected = file.files[0];
    if (!selected || !dialog.open || mode !== "import") return;
    reset();
    if (selected.size > 48 * 1024) {
      message("error", "Choose an agent template up to 48 KiB.");
      return;
    }
    const attempt = sequence, token = app.token;
    busy = true;
    update();
    message("status", "Reading template…");
    try {
      const contents = await selected.text();
      if (!current(attempt, token)) return;
      const template = await preview(contents, token);
      if (!current(attempt, token)) return;
      populate(template);
      message("status", "Template loaded. Review its settings before creating the agent.");
    } catch (error) {
      if (!current(attempt, token)) return;
      busy = false;
      update();
      message("status", "");
      message("error", error.message);
    }
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!app.authorized || !dialog.open || !ready || busy) return;
    const template = {format, ...Object.fromEntries(fields.map((field) => [field, get(field).value]))};
    const attempt = sequence, token = app.token;
    busy = true;
    committing = mode === "import";
    update();
    message("error", "");
    message("status", "");
    try {
      if (mode === "export") {
        const data = await api("/api/profile-templates/preview", template);
        if (!current(attempt, token)) return;
        const blob = new Blob([JSON.stringify(data, null, 2) + "\n"], {type: "application/json"});
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = (data.name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent") + ".swarmhub-agent.json";
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 5000);
        message("status", "Template download started.");
      } else {
        const profile = await api("/api/profile-templates/import", template);
        if (!current(attempt, token)) return;
        dialog.close();
        window.agentProfiles.acceptImport(profile);
      }
    } catch (error) {
      if (!current(attempt, token)) return;
      message("error", error.message);
    } finally {
      if (current(attempt, token)) {
        busy = false;
        committing = false;
        update();
      }
    }
  });
  window.portableProfiles = {render};
})();
