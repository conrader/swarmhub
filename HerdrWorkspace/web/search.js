(() => {
  "use strict";
  const dialog = $("workspace-search");
  const query = $("workspace-query");
  const kind = $("workspace-query-kind");
  const results = $("workspace-search-results");
  const labels = {
    agent:"Agent", group:"Group", page:"Page", message:"Message", file:"File",
    "group-file":"Group file · Download", "group-message":"Group message", "task-file":"Attachment",
    skill:"Skill", routine:"Routine", "routine-draft":"Imported routine draft", snapshot:"Snapshot",
  };
  let revision = 0;
  let timer;

  function lockIfNeeded() {
    if (app.authorized) return;
    if (timer !== undefined) { clearTimeout(timer); timer = undefined; }
    if (dialog.open) { ++revision; dialog.close(); }
    query.value = kind.value = "";
    if (results.childElementCount) results.replaceChildren();
    show("workspace-search-status", "");
  }

  function open() {
    if (!app.authorized) return;
    if (!dialog.open) {
      dialog.showModal();
      queue();
    }
    query.focus();
    query.select();
  }

  function queue() {
    const request = ++revision;
    clearTimeout(timer);
    results.replaceChildren();
    const text = query.value.trim();
    if (!text) {
      show("workspace-search-status", "Search saved messages, skills, routines, Pages, and files.");
      return;
    }
    show("workspace-search-status", "Searching…");
    const params = new URLSearchParams({q:text});
    if (kind.value) params.set("kind", kind.value);
    timer = setTimeout(() => void search(request, params), 170);
  }

  function row(hit) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    const title = document.createElement("strong");
    title.textContent = hit.title;
    const label = document.createElement("small");
    label.textContent = labels[hit.kind];
    button.append(title, label);
    if (hit.excerpt) {
      const excerpt = document.createElement("small");
      excerpt.className = "search-excerpt";
      excerpt.textContent = hit.excerpt;
      button.append(excerpt);
    }
    button.addEventListener("click", () => void visit(hit, button));
    item.append(button);
    return item;
  }

  async function search(request, params) {
    try {
      const hits = await api("/api/search?" + params);
      if (!app.authorized || request !== revision || !dialog.open) return;
      results.replaceChildren(...hits.map(row));
      show("workspace-search-status", hits.length ? `Showing ${hits.length} results.` : "No matching results.");
    } catch (error) {
      if (!app.authorized || request !== revision || !dialog.open) return;
      show("workspace-search-status", error.message);
    }
  }

  async function visit(hit, button) {
    if (!app.authorized) return;
    if (hit.kind === "group-file") {
      button.disabled = true;
      try {
        await downloadBlob(`/api/groups/${hit.group_id}/files/${hit.id}`, hit.title, () => dialog.open);
      } catch {
        if (dialog.open) show("workspace-search-status", "The group file couldn’t be downloaded.");
      } finally {
        button.disabled = false;
      }
      return;
    }
    dialog.close();
    try {
      switch (hit.kind) {
        case "agent": await window.agentProfiles.openById(hit.id); break;
        case "group": await window.groupWorkspace.openById(hit.id); break;
        case "group-message": await window.groupWorkspace.openMessage(hit.group_id, hit.id); break;
        case "page": await window.workspacePages.open(hit.id); break;
        case "skill": await window.workspaceSkills.openById(hit.id); break;
        case "routine": await window.workspaceRoutines.openById(hit.id); break;
        case "routine-draft": await window.workspaceRoutines.openImportedById(hit.id); break;
        case "task-file": {
          const path = `/api/history/${encodeURIComponent(hit.core)}/${encodeURIComponent(hit.address)}/${hit.created_ms}/files/${hit.task_id}/${hit.id}`;
          await showSentFile(path, {kind:"direct",core:hit.core,address:hit.address,created:hit.created_ms,task:hit.task_id,id:hit.id});
          break;
        }
        default:
          if (!$("library").open) $("library").showModal();
          if (hit.kind === "file") await showFile(hit.id);
          else if (hit.kind === "snapshot") await showSnapshot(hit.id);
          else if (hit.kind === "message") showArchive({...hit,agent:hit.title}, hit.id);
      }
    } catch (error) {
      show("notice", error.message);
    }
  }

  $("workspace-search-open").addEventListener("click", open);
  $("workspace-search-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { if (!dialog.open) { ++revision; clearTimeout(timer); } });
  query.addEventListener("input", queue);
  kind.addEventListener("change", queue);
  dialog.addEventListener("keydown", (event) => {
    if (event.isComposing || event.target === kind) return;
    const buttons = Array.from(results.querySelectorAll("button:not(:disabled)"));
    const index = buttons.indexOf(event.target);
    if (event.target === query && event.key === "Enter" && buttons.length) {
      event.preventDefault();
      buttons[0].click();
    } else if (event.key === "ArrowDown" && buttons.length && (index >= 0 || event.target === query)) {
      event.preventDefault();
      (buttons[index + 1] || buttons[0]).focus();
    } else if (event.key === "ArrowUp" && index >= 0) {
      event.preventDefault();
      (buttons[index - 1] || query).focus();
    }
  });
  window.workspaceSearch = { open, lockIfNeeded };
})();
