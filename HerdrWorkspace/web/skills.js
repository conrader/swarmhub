(() => {
  "use strict";

  const dialog = $("skill-dialog");
  const state = { scope: null, insert: null, revision: 0, item: null, rows: [], editing: null, working: false, proposal: null, demonstration: null, grokDraft: null, grokRows: [] };
  const fileInput = $("skill-file");
  const dismiss = document.createElement("button");
  dismiss.type = "button";
  dismiss.hidden = true;
  dismiss.textContent = "Dismiss proposal";
  $("skill-cancel").before(dismiss);
  const imported = document.createElement("section");
  imported.setAttribute("aria-labelledby", "skill-grok-heading");
  imported.hidden = true;
  imported.innerHTML = `<h3 id="skill-grok-heading">Imported Grok skill drafts</h3>
    <p class="subtle">Review these instructions before adding them to the private Skills library.</p>
    <ul id="skill-grok-drafts" class="library-items" aria-label="Imported Grok skill drafts"></ul>`;
  $("skill-list").after(imported);
  const fileFormat = "swarmhub-skill/v1";
  const instructionLimit = 10 * 1024;

  function scope(agent, core = app.core) {
    return agent && core ? {
      core, name: title(agent),
      target: { address: agent.address, created_ms: agent.created_ms },
    } : null;
  }

  function query() {
    if (!state.scope) return "";
    const { core, target } = state.scope;
    return "?" + new URLSearchParams({ core, ...target });
  }

  function mode(section, heading) {
    const current = ++state.revision;
    $("skill-heading").textContent = heading;
    for (const [name, id] of [["list", "skill-list-view"], ["detail", "skill-detail"], ["form", "skill-form"]]) {
      $(id).hidden = section !== name;
    }
    show("skill-notice", "");
    if (section !== "form") { state.proposal = state.demonstration = state.grokDraft = null; dismiss.hidden = true; }
    return current;
  }

  function open(context = null, insert = null) {
    state.scope = context;
    state.insert = insert;
    $("skill-search").value = "";
    $("skill-archived").checked = false;
    dialog.showModal();
    void list();
  }

  async function openById(id) {
    if (!app.authorized || dialog.open) return;
    state.scope = state.insert = null;
    $("skill-search").value = "";
    $("skill-archived").checked = false;
    dialog.showModal();
    await detail(id);
    if (dialog.open && state.item?.id === id && state.item.archived) $("skill-archived").checked = true;
  }

  async function list() {
    const heading = state.insert ? "Use a skill" : state.scope ? `Skills for ${state.scope.name}` : "Skills";
    const revision = mode("list", heading);
    state.item = null;
    state.rows = [];
    state.grokRows = [];
    imported.hidden = true;
    $("skill-list").replaceChildren();
    $("skill-new").hidden = $("skill-archived-label").hidden = Boolean(state.insert);
    $("skill-import").hidden = $("skill-import-help").hidden = Boolean(state.insert);
    $("skill-import").disabled = false;
    show("skill-import-status", "");
    show("skill-notice", "Loading skills…");
    try {
      const [rows, grok] = await Promise.all([api("/api/skills" + query()),
        !state.scope && !state.insert ? api("/api/grok-imports/skill-drafts").catch(() => []) : []]);
      if (revision !== state.revision) return;
      state.rows = rows;
      state.grokRows = grok;
      renderList();
    } catch (error) {
      if (revision === state.revision) show("skill-notice", error.message);
    }
  }

  function renderList() {
    const search = $("skill-search").value.trim().toLowerCase();
    const items = state.rows.filter((skill) => {
      if (state.insert && (!skill.enabled || skill.archived)) return false;
      if (skill.archived && !$("skill-archived").checked) return false;
      return !search || [skill.name, skill.summary].some((value) => value.toLowerCase().includes(search));
    });
    $("skill-list").replaceChildren(...items.map((item) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = item.name;
      const label = document.createElement("small");
      const tags = [item.summary, `Version ${item.version}`];
      if (item.archived) tags.push("Archived");
      else if (!item.enabled) tags.push("Disabled for this agent");
      label.textContent = tags.filter(Boolean).join(" · ");
      button.append(label);
      button.addEventListener("click", () => detail(item.id));
      row.append(button);
      return row;
    }));
    const drafts = state.grokRows.filter((draft) => !search || draft.name.toLowerCase().includes(search));
    imported.hidden = !drafts.length;
    $("skill-grok-drafts").replaceChildren(...drafts.map((draft) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = draft.name;
      const source = document.createElement("small");
      source.textContent = draft.source_file;
      button.append(source);
      button.addEventListener("click", () => void reviewGrok(draft.id));
      row.append(button);
      return row;
    }));
    show("skill-notice", items.length ? "" : "No matching skills.");
  }

  async function detail(id) {
    const revision = mode("detail", "Skill");
    state.item = null;
    for (const control of ["use", "availability", "edit", "archive", "download"]) $("skill-" + control).disabled = true;
    $("skill-download").hidden = Boolean(state.insert);
    $("skill-instructions").textContent = $("skill-summary").textContent = $("skill-version").textContent = "";
    show("skill-notice", "Loading skill…");
    try {
      const item = await api(`/api/skills/${id}` + query());
      if (revision !== state.revision) return;
      state.item = item;
      $("skill-heading").textContent = item.name;
      $("skill-summary").textContent = item.summary;
      $("skill-version").textContent = `Version ${item.version}${item.archived ? " · Archived" : ""}`;
      $("skill-instructions").textContent = item.instructions;
      $("skill-use").hidden = !state.insert;
      $("skill-use").disabled = !state.insert || !item.enabled || item.archived;
      $("skill-edit").hidden = $("skill-archive").hidden = Boolean(state.insert);
      $("skill-edit").disabled = item.archived;
      $("skill-archive").disabled = false;
      $("skill-download").disabled = false;
      $("skill-archive").textContent = item.archived ? "Restore" : "Archive";
      $("skill-availability").hidden = !state.scope || Boolean(state.insert) || item.archived;
      $("skill-availability").disabled = !app.online || state.scope?.core !== app.core;
      $("skill-availability").textContent = item.enabled ? "Disable for agent" : "Enable for agent";
      show("skill-notice", "");
    } catch (error) {
      if (revision === state.revision) show("skill-notice", error.message);
    }
  }

  function edit(item = null, text = "", draft = null) {
    state.editing = item;
    state.proposal = state.grokDraft = null;
    dismiss.hidden = true;
    mode("form", draft ? "Review imported skill" : item ? "Edit skill" : "New skill");
    $("skill-review").hidden = !draft;
    $("skill-name").value = (draft || item)?.name ?? "";
    $("skill-description").value = (draft || item)?.summary ?? "";
    $("skill-text").value = (draft || item)?.instructions ?? text;
    show("skill-error", "");
    $("skill-name").focus();
  }

  async function reviewGrok(id) {
    if (!dialog.open || state.working || !app.authorized) return;
    const revision = mode("", "Review Grok skill draft");
    const token = app.token;
    const current = () => dialog.open && state.revision === revision && app.authorized && token === app.token;
    const path = "/api/grok-imports/skill-drafts/" + id;
    show("skill-notice", "Loading the imported instructions…");
    try {
      const draft = await api(path);
      if (!current()) return;
      if (draft.state === "saved") { await detail(draft.skill); return; }
      if (draft.state !== "pending") { await list(); return; }
      edit(null,"",draft);
      state.grokDraft = path;
      $("skill-heading").textContent = "Review Grok skill draft";
      show("skill-notice", draft.source_file);
      dismiss.textContent = "Dismiss imported draft";
      dismiss.hidden = false;
    } catch (error) {
      if (current()) show("skill-notice", error.message);
    }
  }

  function fromReply(text) {
    state.scope = state.insert = null;
    dialog.showModal();
    edit(null, text);
  }

  function reviewDemonstration(draft, valid) {
    if (dialog.open || state.working || !app.authorized || !valid()) return false;
    state.scope = state.insert = null;
    dialog.showModal();
    edit(null, "", draft);
    state.demonstration = valid;
    $("skill-heading").textContent = "Review demonstrated skill";
    return true;
  }

  function renderDemonstration() {
    if (state.grokDraft && !app.authorized) {
      state.grokDraft = null;
      $("skill-name").value = $("skill-description").value = $("skill-text").value = "";
      if (dialog.open) dialog.close();
    }
    if (!state.demonstration || (app.authorized && state.demonstration())) return;
    state.demonstration = null;
    $("skill-name").value = $("skill-description").value = $("skill-text").value = "";
    if (dialog.open) dialog.close();
  }

  async function reviewProposal(path) {
    if (dialog.open || !app.authorized) return;
    state.scope = state.insert = null;
    const revision = mode("", "Review proposed skill");
    dialog.showModal();
    show("skill-notice", "Loading skill proposal…");
    try {
      const result = await api(path);
      if (!dialog.open || state.revision !== revision) return;
      updateSkillProposal(path, result.state);
      if (result.state === "saved") { await detail(result.skill); return; }
      if (result.state !== "pending") { show("skill-notice", "This proposal was dismissed."); return; }
      edit(null,"",result);
      state.proposal = path;
      $("skill-heading").textContent = "Review proposed skill";
      dismiss.textContent = "Dismiss proposal";
      dismiss.hidden = false;
    } catch (error) {
      if (dialog.open && state.revision === revision) show("skill-notice",error.message);
    }
  }

  dismiss.addEventListener("click", async () => {
    const importedDraft = state.grokDraft;
    const path = importedDraft || state.proposal;
    if (state.working || !path || !app.authorized) return;
    state.working = $("skill-save").disabled = dismiss.disabled = true;
    try {
      await api(path + "/dismiss",{});
      if (importedDraft) {
        if (dialog.open && state.grokDraft === importedDraft) await list();
      } else {
        updateSkillProposal(path, "dismissed");
        dialog.close();
      }
    } catch (error) { show("skill-error",error.message); }
    finally { state.working = $("skill-save").disabled = dismiss.disabled = false; }
  });

  function fitsInstructions(text) {
    return taskOk(text) && new TextEncoder().encode(text).length <= instructionLimit &&
      !/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/.test(text);
  }

  async function readSkill(file) {
    if (file.size > 64 * 1024) throw new Error("Choose a skill file up to 64 KiB.");
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
    } catch {
      throw new Error("Choose a skill file saved as UTF-8 text.");
    }
    let draft;
    if (/\.json$/i.test(file.name)) {
      try { draft = JSON.parse(text); } catch { /* Report an unsupported copy below. */ }
      if (draft?.format !== fileFormat || typeof draft.name !== "string" ||
          typeof draft.summary !== "string" || typeof draft.instructions !== "string") {
        throw new Error("This JSON file isn’t a SwarmHub skill copy.");
      }
    } else if (/\.(md|markdown|txt)$/i.test(file.name)) {
      const title = /^# +(.+?)[ \t]*$/m.exec(text)?.[1];
      const name = title || file.name.replace(/\.[^.]+$/, "");
      draft = { name: [...name.trim()].slice(0, 80).join(""), summary: "", instructions: text };
    } else {
      throw new Error("Choose a Markdown or text file, or a SwarmHub skill copy.");
    }
    draft.instructions = draft.instructions.replace(/\r\n?/g, "\n");
    if (!fitsInstructions(draft.instructions)) {
      throw new Error("The file needs nonempty text instructions of up to 10 KiB.");
    }
    return draft;
  }

  $("skill-import").addEventListener("click", () => fileInput.click());
  fileInput.addEventListener("change", async () => {
    const file = fileInput.files[0];
    fileInput.value = "";
    if (!file || state.insert || !dialog.open || $("skill-list-view").hidden) return;
    const revision = state.revision;
    const current = () => dialog.open && revision === state.revision;
    $("skill-import").disabled = true;
    show("skill-import-status", "Reading skill file…");
    try {
      const draft = await readSkill(file);
      if (current()) edit(null, "", draft);
    } catch (error) {
      if (current()) show("skill-import-status", error.message);
    } finally {
      if (current()) $("skill-import").disabled = false;
    }
  });

  $("skill-download").addEventListener("click", () => {
    if (!state.item || state.insert) return;
    const { name, summary, instructions } = state.item;
    const json = JSON.stringify({ format: fileFormat, name, summary, instructions }, null, 2);
    const link = document.createElement("a");
    const stem = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 70);
    link.download = (stem || "skill") + ".swarmhub-skill.json";
    link.href = URL.createObjectURL(new Blob([json + "\n"], { type: "application/json" }));
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  });

  function append(field, item, limit) {
    if (field.disabled || field.offsetParent === null) return "This draft is no longer open.";
    const prefix = field.value.trimEnd();
    const block = `Skill: ${item.name} (version ${item.version})\n${item.instructions}\nEnd skill`;
    const draft = prefix ? prefix + "\n\n" + block : block;
    if (new TextEncoder().encode(draft).length > limit) return "There isn’t enough room in this draft. Shorten it before adding the skill.";
    field.value = draft;
    field.dispatchEvent(new Event("input"));
    return "";
  }

  $("skills-open").addEventListener("click", () => open());
  $("agent-skills").addEventListener("click", () => open(scope(active())));
  $("task-skill").addEventListener("click", () => {
    const destination = app.selected;
    const core = app.core;
    open(scope(active()), (item) => app.selected !== destination || app.core !== core
      ? "This draft is no longer open." : append($("task"), item, 16384));
  });
  $("skill-close").addEventListener("click", () => { if (!state.working) dialog.close(); });
  $("skill-back").addEventListener("click", () => { if (!state.working) void list(); });
  $("skill-search").addEventListener("input", renderList);
  $("skill-archived").addEventListener("change", renderList);
  $("skill-new").addEventListener("click", () => edit());
  $("skill-edit").addEventListener("click", () => edit(state.item));
  $("skill-cancel").addEventListener("click", () => {
    if (state.working) return;
    if (state.proposal || state.demonstration) { dialog.close(); return; }
    if (state.editing) void detail(state.editing.id);
    else void list();
  });
  $("skill-use").addEventListener("click", () => {
    if (!state.item || $("skill-use").disabled) return;
    const error = state.insert(state.item);
    if (error) show("skill-notice", error);
    else dialog.close();
  });
  dialog.addEventListener("cancel", (event) => { if (state.working) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++state.revision;
    if (state.demonstration || state.grokDraft) $("skill-name").value = $("skill-description").value = $("skill-text").value = "";
    state.scope = state.insert = state.item = state.editing = state.proposal = state.demonstration = state.grokDraft = null;
  });

  $("skill-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (state.working || !app.authorized) return;
    if (state.demonstration && (!app.authorized || !state.demonstration())) {
      renderDemonstration();
      return;
    }
    const item = state.editing;
    const proposal = state.proposal;
    const instructions = $("skill-text").value;
    if (!fitsInstructions(instructions)) {
      show("skill-error", "Enter up to 10 KiB of text instructions.");
      return;
    }
    const body = { name: $("skill-name").value, summary: $("skill-description").value, instructions };
    if (item) body.version = item.version;
    state.working = true;
    $("skill-save").disabled = true;
    show("skill-error", "");
    try {
      const saved = await api(state.grokDraft || proposal || (item ? `/api/skills/${item.id}` : "/api/skills"), body);
      if (proposal) updateSkillProposal(proposal, "saved");
      await detail(saved.id);
    } catch (error) {
      show("skill-error", error.message);
    } finally {
      state.working = false;
      $("skill-save").disabled = false;
    }
  });

  async function change(action) {
    const item = state.item;
    if (!item || state.working) return;
    state.working = true;
    $("skill-archive").disabled = $("skill-availability").disabled = $("skill-edit").disabled = true;
    try {
      await api(`/api/skills/${item.id}/${action}`, action === "archive"
        ? !item.archived : { core: state.scope.core, target: state.scope.target, enabled: !item.enabled });
      await detail(item.id);
    } catch (error) {
      await detail(item.id);
      show("skill-notice", error.message);
    } finally {
      state.working = false;
    }
  }

  $("skill-archive").addEventListener("click", () => change("archive"));
  $("skill-availability").addEventListener("click", () => change("availability"));
  window.workspaceSkills = { open, openById, fromReply, reviewProposal, reviewDemonstration, renderDemonstration, scope, append };
})();
