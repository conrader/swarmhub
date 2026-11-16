(() => {
  "use strict";

  function button(id, title, after, className = "") {
    const element = document.createElement("button");
    element.id = id;
    element.type = "button";
    element.className = className;
    element.textContent = title;
    element.hidden = id !== "github-project-open";
    element.disabled = true;
    $(after).after(element);
    return element;
  }

  const opener = button("github-project-open", "GitHub project", "connected-files-open", "new");
  const direct = button("github-project-direct", "From GitHub", "connected-attach");
  const group = button("github-project-group", "From GitHub", "group-attach");
  const dialog = document.createElement("dialog");
  dialog.id = "github-project-dialog";
  dialog.setAttribute("aria-labelledby", "github-project-heading");
  dialog.innerHTML = `
    <div class="details-header"><h2 id="github-project-heading">GitHub project</h2><button type="button" id="github-project-close" class="icon" aria-label="Close GitHub project">×</button></div>
    <p id="github-project-context" class="subtle"></p>
    <p id="github-project-status" role="status" hidden></p>
    <section id="github-project-browser" aria-label="Open issues and pull requests" hidden>
      <ul id="github-project-items" class="library-items" aria-label="Open issues and pull requests"></ul>
      <button type="button" id="github-project-more" hidden>Load more</button>
    </section>
    <section id="github-project-detail" aria-labelledby="github-project-title" hidden>
      <button type="button" id="github-project-back">Back to open items</button>
      <h3 id="github-project-title"></h3>
      <p id="github-project-source" class="subtle"></p>
      <div id="github-project-excerpt" class="notice" style="white-space:pre-wrap"></div>
      <p id="github-project-truncated" class="subtle" hidden>This excerpt has been shortened.</p>
      <div class="dialog-actions"><button type="button" id="github-project-attach" class="primary" hidden>Attach excerpt to draft</button></div>
    </section>`;
  document.body.append(dialog);

  let statusToken = null;
  let repository = null;
  let request = 0;
  let destination = null;
  let entries = [];
  let more = null;
  let selected = null;

  function draft() {
    if (window.groupWorkspace?.active()) {
      const slot = window.groupWorkspace.attachmentDraft();
      return slot?.canAdd ? {kind:"group", key:slot.key, bytes:slot.bytes} : null;
    }
    const slot = directAttachmentDraft();
    return slot?.canAdd ? {kind:"direct", key:slot.key, bytes:slot.bytes} : null;
  }

  async function checkConfig() {
    const token = app.token;
    statusToken = token;
    repository = null;
    try {
      const result = await api("/api/github-project/status");
      if (app.token === token && statusToken === token && app.authorized) repository = result.repository;
    } catch { /* The browse dialog can retry. */ }
    if (app.token === token && statusToken === token) update();
  }

  function update() {
    opener.disabled = !app.authorized;
    if (!app.authorized) {
      if (dialog.open) {
        ++request;
        dialog.close();
      }
      statusToken = repository = null;
    } else if (app.token !== statusToken) void checkConfig();
    const target = draft();
    direct.hidden = group.hidden = !repository;
    direct.disabled = !app.authorized || target?.kind !== "direct" || target.bytes < 1;
    group.disabled = !app.authorized || target?.kind !== "group" || target.bytes < 1;
    const same = destination && target?.kind === destination.kind && target.key === destination.key;
    $("github-project-attach").disabled = !same || !selected || new TextEncoder().encode(selected.attachment).length > target.bytes;
    window.swarmGitHubAccess?.render();
  }

  function present() {
    const list = $("github-project-items");
    list.replaceChildren(...entries.map((item) => {
      const row = document.createElement("li");
      const open = document.createElement("button");
      open.type = "button";
      const kind = item.kind === "issue" ? "Issue" : "Pull request";
      open.textContent = `${kind} #${item.number}: ${item.title}`;
      open.addEventListener("click", () => void read(item, open));
      row.append(open);
      return row;
    }));
    $("github-project-more").hidden = !more;
  }

  function current(sequence, token) {
    return app.authorized && app.token === token && dialog.open && sequence === request;
  }

  async function browse(page = 1) {
    const seq = ++request;
    const token = app.token;
    const load = $("github-project-more");
    load.disabled = true;
    show("github-project-status", "Loading open issues and pull requests…");
    try {
      const result = await api("/api/github-project/items?" + new URLSearchParams({page}));
      if (!current(seq, token)) return;
      entries = page === 1 ? result.entries : [...entries, ...result.entries];
      more = result.next_page;
      present();
      show("github-project-status", entries.length ? "" : "No open issues or pull requests.");
      if (page === 1) $("github-project-items").querySelector("button")?.focus();
    } catch (error) {
      if (current(seq, token)) show("github-project-status", error.message);
    } finally {
      if (current(seq, token)) load.disabled = false;
    }
  }

  async function read(item, backTo) {
    const seq = ++request;
    const token = app.token;
    show("github-project-status", "Loading excerpt…");
    try {
      const result = await api("/api/github-project/item?" + new URLSearchParams({kind:item.kind, number:item.number}));
      if (!current(seq, token)) return;
      selected = result;
      $("github-project-title").textContent = result.title;
      $("github-project-source").textContent = result.source;
      $("github-project-excerpt").textContent = result.excerpt || "No description provided.";
      $("github-project-truncated").hidden = !result.truncated;
      $("github-project-browser").hidden = true;
      $("github-project-detail").hidden = false;
      $("github-project-attach").hidden = !destination;
      $("github-project-back").relatedItem = backTo;
      show("github-project-status", "");
      update();
      $("github-project-back").focus();
    } catch (error) {
      if (current(seq, token)) show("github-project-status", error.message);
    }
  }

  async function open(useDraft) {
    if (!app.authorized || dialog.open) return;
    destination = useDraft ? draft() : null;
    if (useDraft && !destination) return;
    const seq = ++request;
    const token = app.token;
    selected = null;
    entries = [];
    more = null;
    present();
    $("github-project-detail").hidden = $("github-project-browser").hidden = true;
    $("github-project-context").textContent = "";
    show("github-project-status", "Checking GitHub project…");
    dialog.showModal();
    try {
      const result = await api("/api/github-project/status");
      if (!current(seq, token)) return;
      if (!result.repository) {
        show("github-project-status", "No GitHub repository is configured. The workspace administrator can connect one.");
        return;
      }
      $("github-project-context").textContent = result.repository + (destination ? " · Review an excerpt before attaching" : " · Open issues and pull requests");
      $("github-project-browser").hidden = false;
      void browse();
    } catch (error) {
      if (current(seq, token)) show("github-project-status", error.message);
    }
  }

  opener.addEventListener("click", () => void open(false));
  direct.addEventListener("click", () => void open(true));
  group.addEventListener("click", () => void open(true));
  $("github-project-close").addEventListener("click", () => dialog.close());
  $("github-project-more").addEventListener("click", () => { if (more) void browse(more); });
  $("github-project-back").addEventListener("click", (event) => {
    $("github-project-detail").hidden = true;
    $("github-project-browser").hidden = false;
    selected = null;
    event.currentTarget.relatedItem?.focus();
  });
  $("github-project-attach").addEventListener("click", () => {
    const target = draft();
    if (!app.authorized || !target || target.kind !== destination?.kind || target.key !== destination.key || !selected) {
      show("github-project-status", "The original draft is no longer available.");
      return;
    }
    const file = new File([selected.attachment], selected.file_name, {type:"text/plain"});
    const added = target.kind === "group"
      ? window.groupWorkspace.addDraftAttachment(target.key, file)
      : addDirectDraftAttachment(target.key, file);
    if (!added) {
      show("github-project-status", "This draft cannot accept another attachment.");
      return;
    }
    dialog.close();
    $(target.kind === "group" ? "group-task" : "task").focus();
  });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++request;
    destination = selected = null;
    entries = [];
    more = null;
    present();
    $("github-project-source").textContent = $("github-project-title").textContent = $("github-project-excerpt").textContent = "";
    $("github-project-back").relatedItem = null;
  });

  window.workspaceGitHubProject = {update, repository:() => repository};
})();
