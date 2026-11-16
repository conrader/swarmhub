(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const dialog = $("grok-import-dialog");
  let rows = [];
  let skills = [];
  let skillNote = "";
  let previewing = null;
  let saving = false;
  const selected = () => rows.filter((row) => row.preview && row.checked && !row.saved);
  const selectedSkills = () => skills.filter((row) => row.file && row.checked && !row.saved);
  const quantity = (n, single) => n + " " + single + (n === 1 ? "" : "s");
  const skillPanel = document.createElement("section");
  skillPanel.setAttribute("aria-labelledby", "grok-skill-heading");
  skillPanel.innerHTML = `
    <h3 id="grok-skill-heading">Skill instruction files</h3>
    <p class="subtle">Select the files you want to prepare as drafts. Skills stay inactive until you review and save them from the Skills library.</p>
    <ul id="grok-skill-files" class="grok-import-preview" aria-label="Indexed skill files"></ul>
    <p id="grok-skill-status" role="status" hidden></p>
    <div class="grok-import-actions"><button type="button" id="grok-skill-stage">Prepare selected skill drafts</button><button type="button" id="grok-skill-review">Open Skills library</button></div>`;
  $("grok-import-preview").after(skillPanel);
  skillPanel.hidden = true;
  const utf8 = new TextEncoder();
  const skillPath = (value) => {
    if (typeof value !== "string") return false;
    const parts = value.split("/");
    const name = parts[1];
    return parts.length === 3 && parts[0] === "skills" && parts[2] === "SKILL.md"
      && name && name === name.trim() && name !== "." && name !== ".." && utf8.encode(name).length <= 160
      && !/[\\:%\p{Cc}\u2028\u2029]/u.test(name);
  };

  async function send(path, file, signal) {
    let response;
    try {
      const headers = { Authorization: "Bearer " + app.token };
      if (!(file instanceof FormData)) headers["Content-Type"] = "application/octet-stream";
      response = await fetch(path, {method: "POST", body: file, signal, headers});
    } catch {
      throw new Error("The workspace connection was lost. Try this file again.");
    }
    const data = await response.json().catch(() => null);
    if (!response.ok || !data) {
      throw new Error(data?.error || (response.status === 413 ? "This bundle or its attachments exceed the import limit." : `Import failed (HTTP ${response.status}).`));
    }
    return data;
  }

  function showButtons() {
    $("grok-import-save").disabled = saving || Boolean(previewing) || !selected().length;
    $("grok-import-pick-folder").disabled = $("grok-import-pick-files").disabled = saving || Boolean(previewing);
    $("grok-import-history").disabled = $("grok-import-close").disabled = saving;
    $("grok-skill-stage").disabled = saving || Boolean(previewing) || !selectedSkills().length;
    $("grok-skill-review").disabled = saving || Boolean(previewing);
  }

  $("grok-export-helper").addEventListener("click", async () => {
    const button = $("grok-export-helper");
    button.disabled = true;
    show("grok-export-helper-status", "Preparing download…");
    try {
      await downloadBlob("/api/grok-imports/export-helper", "swarmhub-grok-export.pyz", () => dialog.open && app.authorized);
      if (dialog.open) show("grok-export-helper-status", "Download started. Run the command on your Mac to create the export folder.");
    } catch {
      if (dialog.open) show("grok-export-helper-status", "The helper couldn’t be downloaded. Try again.");
    } finally { button.disabled = false; }
  });

  function draw() {
    const nodes = rows.map((row) => {
      const li = document.createElement("li");
      const details = row.preview;
      if (!details) {
        const name = document.createElement("strong");
        name.textContent = row.file.webkitRelativePath || row.file.name;
        const error = document.createElement("p");
        error.className = "error";
        error.textContent = row.error;
        li.append(name, error);
        return li;
      }
      const choice = document.createElement("label");
      choice.className = "routine-check";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = row.checked;
      box.disabled = saving || Boolean(row.saved);
      box.addEventListener("change", () => { row.checked = box.checked; showButtons(); });
      choice.append(box, document.createTextNode(details.name));
      li.append(choice);
      const summary = document.createElement("p");
      summary.className = "subtle";
      summary.textContent = [
        details.is_group ? "Read-only group archive" : "Agent profile and read-only history",
        quantity(details.visible_messages, "message"),
        details.already_saved ? "Already saved; add missing messages and files" : "",
      ].filter(Boolean).join(" · ");
      li.append(summary);
      const limitations = [
        details.skipped_messages ? quantity(details.skipped_messages, "hidden, unsupported, or duplicate message") + " skipped" : "",
        details.shortened_messages ? quantity(details.shortened_messages, "large message") + " shortened" : "",
        details.attachments ? quantity(details.attachments, "attachment reference") : "",
        row.files.length ? quantity(row.files.length, "local file") + " ready to import" : "",
        details.attachments && !row.files.length ? "No matching local files selected" : "",
        details.skipped_routines ? quantity(details.skipped_routines, "routine") + " not imported" : "",
        details.skills ? quantity(details.skills, "skill reference") + " · indexed instruction files only" : "",
        details.connectors ? quantity(details.connectors, "connector") + " not imported" : "",
      ].filter(Boolean);
      if (limitations.length) {
        const limited = document.createElement("p");
        limited.className = "subtle";
        limited.textContent = limitations.join(" · ");
        li.append(limited);
      }
      if (details.routines) {
        const drafts = document.createElement("p");
        drafts.className = "subtle";
        drafts.textContent = quantity(details.routines, "routine draft") + " to review in Routines";
        li.append(drafts);
      }
      if (details.instructions) {
        const review = document.createElement("details");
        const title = document.createElement("summary");
        title.textContent = "Review standing instructions";
        const instructions = document.createElement("p");
        instructions.textContent = details.instructions;
        review.append(title, instructions);
        li.append(review);
      }
      if (details.attachment_names?.length) {
        const files = document.createElement("details");
        const title = document.createElement("summary");
        title.textContent = "View expected attachment names";
        const names = document.createElement("p");
        names.textContent = details.attachment_names.join(", ");
        files.append(title, names);
        li.append(files);
      }
      if (row.saved || row.error) {
        const status = document.createElement("p");
        status.className = row.error ? "error" : "subtle";
        status.textContent = row.error || [
          "Saved", row.saved.added ? quantity(row.saved.added, "message") + " added" : "no new messages",
          row.saved.added_files ? quantity(row.saved.added_files, "attachment") + " added" : "",
          row.saved.routine_drafts ? quantity(row.saved.routine_drafts, "routine draft") + " added" : "",
        ].filter(Boolean).join(" · ");
        li.append(status);
      }
      return li;
    });
    $("grok-import-preview").replaceChildren(...nodes);
    showButtons();
  }

  function drawSkills(status = skillNote) {
    skillPanel.hidden = !skills.length && !skillNote;
    $("grok-skill-files").replaceChildren(...skills.map((row) => {
      const li = document.createElement("li");
      const name = document.createElement("label");
      name.className = "routine-check";
      const choice = document.createElement("input");
      choice.type = "checkbox";
      choice.checked = row.checked;
      choice.disabled = saving || !row.file || Boolean(row.saved);
      choice.addEventListener("change", () => { row.checked = choice.checked; showButtons(); });
      name.append(choice,document.createTextNode(row.name));
      const line = document.createElement("p");
      line.className = row.error ? "error" : "subtle";
      line.textContent = row.error || (!row.file ? "Instruction file not found: " + row.path
        : row.saved?.state === "saved" ? "Already saved to the Skills library."
        : row.saved?.state === "dismissed" ? "Already dismissed."
        : row.saved ? "Ready for review in Skills." : row.path);
      li.append(name,line);
      return li;
    }));
    show("grok-skill-status", status);
    showButtons();
  }

  async function indexSkills(folder, signal) {
    const rootIndex = [...folder.entries()].find(([path]) => /^([^/]+)\/index\.json$/.test(path));
    if (!rootIndex) return {rows: [], note: ""};
    const [path,index] = rootIndex;
    const prefix = path.slice(0,-"index.json".length);
    try {
      if (index.size > 512 * 1024) throw new Error();
      const value = JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(await index.arrayBuffer()));
      if (signal.aborted) return {rows: [], note: ""};
      if (value?.format !== "agentapp-bot-bundle/v1" || !Array.isArray(value.skills)) return {rows: [], note: ""};
      if (value.skills.length > 100) return {rows: [], note: "This index lists more than 100 skills. Import individual Markdown files in Skills."};
      const rows = [];
      const paths = new Set();
      let unsupported = 0;
      for (const entry of value.skills) {
        const name = typeof entry?.name === "string" && entry.name.trim();
        if (!name || [...name].length > 80 || /\p{Cc}/u.test(entry.name) || !skillPath(entry.file)) {
          ++unsupported;
          continue;
        }
        if (paths.has(entry.file)) continue;
        paths.add(entry.file);
        rows.push({name,path:entry.file,file:folder.get(prefix+entry.file),checked:false});
      }
      return {rows,note: unsupported ? quantity(unsupported,"unsupported skill reference") + " ignored." : ""};
    } catch {
      return {rows: [], note: "Couldn’t read the skill index. Import individual Markdown files in Skills."};
    }
  }

  function localCopies(bundle, names, folder) {
    if (!bundle.webkitRelativePath) return [];
    const prefix = bundle.webkitRelativePath.slice(0, -bundle.name.length) + "attachments/";
    const copies = [];
    let remaining = 8 * 1024 * 1024;
    for (const name of names) {
      const file = folder.get(prefix + name);
      if (!file || file.size > remaining) continue;
      copies.push(file);
      remaining -= file.size;
      if (copies.length === 32) break;
    }
    return copies;
  }

  async function inspect(files, folder = new Map()) {
    const task = new AbortController();
    previewing?.abort();
    previewing = task;
    rows = [];
    skills = [];
    skillNote = "";
    draw();
    drawSkills();
    if (folder.size) {
      const indexed = await indexSkills(folder, task.signal);
      if (task.signal.aborted) return;
      skills = indexed.rows;
      skillNote = indexed.note;
      drawSkills();
    }
    if (!files.length || files.length > 50) {
      previewing = null;
      show("grok-import-status", files.length ? "Choose up to 50 bundles at a time." : skills.length
        ? "No conversation bundles in this folder. Review the indexed skill files below."
        : "No bundle.json files found in this selection.");
      showButtons();
      return;
    }
    for (const [index, file] of files.entries()) {
      if (task.signal.aborted) return;
      show("grok-import-status", `Checking bundle ${index + 1} of ${files.length}…`);
      const row = {file, files: [], checked: true};
      try {
        if (file.size > 16 * 1024 * 1024) throw new Error("This bundle exceeds 16 MiB.");
        row.preview = await send("/api/grok-imports/preview", file, task.signal);
        row.files = localCopies(file, row.preview.attachment_names || [], folder);
      } catch (error) { row.error = error.message; }
      if (task.signal.aborted) return;
      rows.push(row);
      draw();
    }
    previewing = null;
    show("grok-import-status", selected().length
      ? "Review the selection. Importing does not start agents or send messages."
      : "No supported bundles in this selection.");
    showButtons();
  }

  $("grok-import-open").addEventListener("click", () => {
    rows = [];
    skills = [];
    skillNote = "";
    show("grok-import-status", "");
    draw();
    drawSkills();
    dialog.showModal();
  });
  $("grok-import-close").addEventListener("click", () => { if (!saving) dialog.close(); });
  dialog.addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    previewing?.abort();
    previewing = null;
    rows = [];
    skills = [];
    skillNote = "";
    draw();
    drawSkills();
  });
  for (const key of ["folder", "files"]) {
    const input = $("grok-import-" + key);
    $("grok-import-pick-" + key).addEventListener("click", () => input.click());
    input.addEventListener("change", () => {
      const picked = [...input.files];
      input.value = "";
      if (!picked.length) return;
      if (key === "folder") {
        const folder = new Map(picked.map((file) => [file.webkitRelativePath, file]));
        const bundles = picked.filter((file) => file.name === "bundle.json" &&
          !file.webkitRelativePath.split("/").slice(1, -1).includes("attachments"));
        void inspect(bundles, folder);
      } else {
        void inspect(picked);
      }
    });
  }
  $("grok-import-pick-folder").hidden = !("webkitdirectory" in $("grok-import-folder"));
  $("grok-import-history").addEventListener("click", () => {
    if (saving) return;
    dialog.close();
    if (!$("library").open) $("library").showModal();
    void showLibrary("grok");
  });
  $("grok-skill-review").addEventListener("click", () => {
    if (saving || previewing) return;
    dialog.close();
    window.workspaceSkills.open();
  });
  $("grok-skill-stage").addEventListener("click", async () => {
    if (saving || previewing) return;
    const batch = selectedSkills();
    if (!batch.length) return;
    saving = true;
    drawSkills();
    let count = 0;
    try {
      for (const [index,row] of batch.entries()) {
        show("grok-skill-status", `Preparing skill ${index+1} of ${batch.length}…`);
        try {
          if (row.file.size > 10 * 1024) throw new Error("This instruction file exceeds 10 KiB. Shorten it before importing.");
          const bytes = await row.file.arrayBuffer();
          let text;
          try { text = new TextDecoder("utf-8", {fatal:true}).decode(bytes); }
          catch { throw new Error("This skill file is not UTF-8 Markdown."); }
          row.saved = await api("/api/grok-imports/skill-drafts", {file:row.path,name:row.name,instructions:text});
          row.error = "";
          count++;
        } catch (error) { row.error = error.message; }
      }
    } finally {
      saving = false;
      drawSkills(count < batch.length ? "Check the highlighted files. Review prepared drafts in Skills."
        : "Open the Skills library to review the prepared drafts.");
    }
  });
  $("grok-import-save").addEventListener("click", async () => {
    if (saving || previewing) return;
    const batch = selected();
    if (!batch.length) return;
    saving = true;
    draw();
    let count = 0;
    let added = 0;
    for (const [index, row] of batch.entries()) {
      show("grok-import-status", `Importing bundle ${index + 1} of ${batch.length}…`);
      try {
        if (row.files.length) {
          const form = new FormData();
          form.append("bundle", row.file, "bundle.json");
          for (const file of row.files) form.append("file", file, file.name);
          row.saved = await send("/api/grok-imports/with-files", form);
        } else {
          row.saved = await send("/api/grok-imports", row.file);
        }
        row.error = "";
        ++count;
        added += row.saved.added;
      } catch (error) { row.error = error.message; }
      draw();
    }
    saving = false;
    show("grok-import-status", `Saved ${quantity(count, "bundle")} · ${quantity(added, "new message")}.`
      + (count < batch.length ? " Check the failed bundles and retry." : " Open Grok Bot history to read them."));
    draw();
    if (count) {
      await window.agentProfiles.load().catch(() => {});
      renderState();
    }
  });
})();
