(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const dialog = $("connected-files-dialog");
  const list = $("connected-files-list");
  let path = "";
  let source = "webdav";
  let target = null;
  let request = 0;
  let moving = false;
  let exporting = null;
  let ready = false;
  const endpoint = () => source === "drive" ? "/api/drive-files" : "/api/connected-files";
  const capabilities = () => Promise.all([api("/api/connected-files/capabilities"),api("/api/drive-files/status")]
    .map((result) => result.catch(() => null)));
  const sameDraft = () => target !== null && target === draftKey() && app.online;

  function size(bytes) {
    if (bytes === null) return "File";
    if (bytes < 1024) return bytes + " bytes";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KiB";
    return (bytes / (1024 * 1024)).toFixed(1) + " MiB";
  }

  function row(entry) {
    const item = document.createElement("li");
    const text = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = entry.name;
    const detail = document.createElement("small");
    detail.textContent = entry.folder ? "Folder" : size(entry.bytes);
    text.append(name, detail);
    item.append(text);
    const segment = source === "drive" ? entry.id : entry.name;
    const next = path ? path + "/" + segment : segment;
    if (entry.folder || target !== null) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = entry.folder ? "Open" : "Attach";
      button.setAttribute("aria-label", (entry.folder ? "Open " : "Attach ") + entry.name);
      const tooLarge = !entry.folder && entry.bytes !== null && entry.bytes > 8 * 1024 * 1024;
      button.disabled = moving || (!entry.folder && (!sameDraft() || !canStageAttachment() || fileDraft().files.length >= 4 || tooLarge || entry.attachable === false));
      if (tooLarge) detail.textContent += " · Over the 8 MiB limit";
      else if (entry.attachable === false && !entry.folder) detail.textContent += " · Unavailable to attach";
      button.addEventListener("click", () => entry.folder ? browse(next) : attach(next));
      item.append(button);
    }
    return item;
  }

  async function browse(next) {
    if (moving) return;
    const seq = ++request;
    ready = false;
    $("connected-save").disabled = true;
    list.replaceChildren();
    $("connected-files-up").disabled = true;
    $("connected-save-hint").textContent = source === "drive" ? "Google Drive creates a separate copy, even if a file has the same name."
      : "This creates a new file. Choose a different name if one already exists.";
    show("connected-files-status", "Loading folder…");
    try {
      const result = await api(endpoint() + "?" + new URLSearchParams({path:next}));
      if (seq !== request || !dialog.open) return;
      if (!result.configured) {
        $("connected-files-path").textContent = "";
        $("connected-files-target").textContent = "";
        show("connected-files-status", "No WebDAV folder is configured. The workspace administrator can connect one.");
        return;
      }
      path = result.path;
      ready = Boolean(result.uploads);
      $("connected-files-path").textContent = source === "drive" ? `Google Drive / ${result.label}`
        : path ? "Connected folder / " + path.split("/").join(" / ") : "Connected folder";
      $("connected-files-up").hidden = !path;
      list.replaceChildren(...result.entries.filter((entry) => !exporting || entry.folder).map(row));
      $("connected-save").disabled = !ready;
      show("connected-files-status", exporting && !ready ? "This folder can’t accept new files. Choose another folder."
        : result.truncated ? "This folder has more results than could be loaded."
        : result.entries.length || exporting ? "" : "This folder is empty.");
      if (path) $("connected-files-up").focus();
      else if (list.children.length) list.querySelector("button")?.focus();
    } catch (error) {
      if (seq === request && dialog.open) show("connected-files-status", error.message);
    } finally {
      if (seq === request) $("connected-files-up").disabled = false;
    }
  }

  async function attach(file) {
    if (moving || !sameDraft() || !canStageAttachment()) {
      show("connected-files-status", "Open the connected folder from a running agent to attach a file.");
      return;
    }
    moving = true;
    const enabled = [...list.querySelectorAll("button:not(:disabled)")];
    for (const button of enabled) button.disabled = true;
    $("connected-files-close").disabled = $("connected-files-up").disabled = true;
    show("connected-files-status", "Attaching to your draft…");
    try {
      const ok = await queueConnectedFile(async () => {
        const response = await fetch(endpoint() + "/file?" + new URLSearchParams({path:file}), {
          headers:{Authorization:"Bearer " + app.token},
        });
        if (!response.ok) {
          const body = await response.json().catch(() => null);
          throw new Error(body?.error || `The file couldn’t be read (HTTP ${response.status}).`);
        }
        const header = response.headers.get("Content-Disposition")?.split("filename*=UTF-8''")[1];
        return new File([await response.blob()],header ? decodeURIComponent(header) : file.split("/").at(-1));
      }, (message) => show("connected-files-status", message));
      if (ok) {
        dialog.close();
        $("task").focus();
      } else {
        for (const button of enabled) button.disabled = false;
      }
    } finally {
      moving = false;
      $("connected-files-close").disabled = $("connected-files-up").disabled = false;
    }
  }

  function open(useDraft, exportFile = null, finish = null) {
    if (!app.authorized || dialog.open) return;
    exporting = exportFile ? { file: exportFile, finish } : null;
    target = useDraft && canStageAttachment() ? draftKey() : null;
    $("connected-files-heading").textContent = exporting ? "Save to connected folder" : "Connected files";
    $("connected-files-target").textContent = exporting ? "Choose where to save a copy of " + exportFile.name + "." : target
      ? `Attach a file to ${window.agentProfiles.current()?.name || title(active())}’s draft.`
      : "Browse files from your workspace connections.";
    $("connected-save-form").hidden = !exporting;
    $("connected-save-name").value = exporting ? exportFile.name : "";
    $("connected-save").disabled = true;
    $("connected-files-path").textContent = "";
    $("connected-files-up").hidden = true;
    path = "";
    source = "webdav";
    $("connected-files-source-field").hidden = true;
    $("drive-setup").hidden = true;
    $("drive-authorize").hidden = $("drive-check").hidden = true;
    $("drive-authorize").removeAttribute("href");
    show("drive-setup-status", "");
    dialog.showModal();
    void chooseSources();
  }

  async function chooseSources(preferred = "") {
    const seq = ++request;
    show("connected-files-status", "Checking connected sources…");
    const [dav, drive] = await capabilities();
    if (seq !== request || !dialog.open) return;
    $("drive-setup").hidden = Boolean(exporting) || !drive?.connectable;
    $("drive-connect").textContent = drive?.configured ? "Reconnect Google Drive" : "Connect Google Drive";
    $("drive-disconnect").hidden = !drive?.configured;
    if (preferred === "drive") {
      show("drive-setup-status", drive?.configured ? "Google Drive is available."
        : "Drive is not connected yet. Finish consent in the Google tab and check again.");
      if (drive?.configured) {
        $("drive-authorize").hidden = $("drive-check").hidden = true;
        $("drive-authorize").removeAttribute("href");
        void refresh();
      }
    }
    const providers = [];
    if (dav?.configured && (!exporting || dav.uploads)) providers.push(new Option("WebDAV folder","webdav"));
    if (drive?.configured && (!exporting || drive.uploads)) providers.push(new Option("Google Drive","drive"));
    if (!providers.length) {
      show("connected-files-status", dav || drive ? exporting ? "No connected destination accepts copies."
        : "No file source is connected to this workspace." : "The workspace couldn’t check its file connections.");
      return;
    }
    const choices = $("connected-files-source");
    choices.replaceChildren(...providers);
    if (providers.some((option) => option.value === preferred)) choices.value = preferred;
    $("connected-files-source-field").hidden = providers.length < 2;
    source = choices.value;
    await browse("");
  }

  $("drive-connect").addEventListener("click", async () => {
    const seq = request;
    const start = $("drive-connect");
    start.disabled = true;
    $("drive-authorize").hidden = $("drive-check").hidden = true;
    $("drive-authorize").removeAttribute("href");
    show("drive-setup-status", "Preparing Google consent…");
    try {
      const {url} = await api("/api/drive-files/connect", {});
      if (!dialog.open || seq !== request) return;
      const target = new URL(url);
      if (target.origin !== "https://accounts.google.com" || target.pathname !== "/o/oauth2/v2/auth") {
        throw new Error("The Google authorization link was invalid.");
      }
      $("drive-authorize").href = target.href;
      $("drive-authorize").hidden = $("drive-check").hidden = false;
      show("drive-setup-status", "Open the Google consent link, then return here and check the connection.");
      $("drive-authorize").focus();
    } catch (error) {
      if (dialog.open && seq === request) show("drive-setup-status",error.message);
    } finally { start.disabled = false; }
  });
  $("drive-check").addEventListener("click", () => void chooseSources("drive"));
  $("drive-disconnect").addEventListener("click", async () => {
    const button = $("drive-disconnect");
    button.disabled = $("drive-connect").disabled = true;
    try {
      await api("/api/drive-files/disconnect", {});
      if (!dialog.open) return;
      $("drive-authorize").hidden = $("drive-check").hidden = true;
      $("drive-authorize").removeAttribute("href");
      list.replaceChildren();
      $("connected-files-path").textContent = "";
      $("connected-files-up").hidden = true;
      show("drive-setup-status","Google Drive disconnected from this workspace.");
      await chooseSources();
      if (dialog.open && !$("drive-setup").hidden) $("drive-connect").focus();
    } catch (error) {
      if (dialog.open) show("drive-setup-status",error.message);
    } finally {
      button.disabled = $("drive-connect").disabled = false;
      void refresh();
    }
  });

  $("connected-save-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (moving || !ready || !exporting) return;
    const name = $("connected-save-name").value;
    const enabled = [...list.querySelectorAll("button:not(:disabled)")];
    moving = true;
    for (const button of enabled) button.disabled = true;
    for (const id of ["connected-files-close","connected-files-up","connected-save","connected-save-name","connected-files-source"]) $(id).disabled = true;
    show("connected-files-status", "Saving copy…");
    try {
      const saved = await api(endpoint() + "/export", {source:exporting.file.source, folder:path, name});
      const finish = exporting.finish;
      dialog.close();
      finish?.(saved);
    } catch (error) {
      show("connected-files-status", error.message);
    } finally {
      moving = false;
      for (const id of ["connected-files-close","connected-files-up","connected-save","connected-save-name","connected-files-source"]) $(id).disabled = false;
      for (const button of enabled) button.disabled = false;
      if (dialog.open) $("connected-save-name").focus();
    }
  });

  $("connected-files-open").addEventListener("click", () => open(false));
  $("connected-attach").addEventListener("click", () => open(true));
  $("connected-files-source").addEventListener("change", (event) => {
    if (moving) { event.target.value = source; return; }
    source = event.target.value;
    path = "";
    $("connected-files-path").textContent = "";
    $("connected-files-up").hidden = true;
    void browse("");
  });
  $("connected-files-up").addEventListener("click", () => void browse(path.split("/").slice(0,-1).join("/")));
  $("connected-files-close").addEventListener("click", () => { if (!moving) dialog.close(); });
  dialog.addEventListener("cancel", (event) => { if (moving) event.preventDefault(); });
  dialog.addEventListener("close", () => { if (!dialog.open) { ++request; list.replaceChildren(); exporting = null; ready = false; } });
  window.connectedFiles = { save: (file, done) => open(false, file, done),
    canSave: async () => (await capabilities()).some((source) => source?.uploads) };
})();
