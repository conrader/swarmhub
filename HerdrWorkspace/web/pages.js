(() => {
  "use strict";
  let current = null;
  let sequence = 0;
  let saving = false;
  let discussing = false;
  let thread = null;
  let threadSignature = null;
  let sending = false;
  let checking = false;
  let checklistStale = false;
  let threadRequest = 0;
  let versionRequest = 0;
  let viewedHash = "";
  let handledHash = null;
  let missingRevision = null;
  let tableViews = new Map();
  const dialog = $("page-dialog");
  const checkboxes = () => [...$("page-markdown-preview").querySelectorAll('input[type="checkbox"]')];
  const isHistorical = () => current?.current_revision > current?.revision;

  function refreshLibraryList() {
    if ($("library").open && !$("library-items").hidden && ["pages", "results"].includes(app.libraryKind)) {
      void showLibrary(app.libraryKind);
    }
  }

  function pageHash(id, revision) {
    return `#page=${id}${revision == null ? "" : "&revision=" + revision}`;
  }

  function setLocation(hash, replace) {
    const url = new URL(location.href);
    url.hash = hash;
    if (url.href !== location.href) history[replace ? "replaceState" : "pushState"](history.state, "", url);
    handledHash = viewedHash = hash;
  }

  function syncLocation() {
    if (!app.authorized) {
      window.pageShare.close();
      if (dialog.open) {
        viewedHash = "";
        current = null;
        thread = threadSignature = null;
        tableViews.clear();
        $("page-heading").textContent = "Page";
        for (const id of ["page-markdown-preview", "page-revision-list", "page-tasks"]) $(id).replaceChildren();
        for (const field of ["page-title", "page-markdown", "page-task-text", "page-link-value"]) $(field).value = "";
        dialog.close();
      }
      handledHash = null;
      return;
    }
    if (location.hash === handledHash) return;
    const match = /^#page=([1-9]\d*)(?:&revision=([1-9]\d*))?$/.exec(location.hash);
    const id = Number(match?.[1]);
    const revision = match?.[2] ? Number(match[2]) : null;
    const isPage = Number.isSafeInteger(id) && (revision == null || Number.isSafeInteger(revision));
    if (dialog.open && (viewedHash || isPage || location.hash.startsWith("#agent=")) && !canClose()) {
      setLocation(viewedHash, false);
      return;
    }
    handledHash = location.hash;
    if (isPage) {
      viewedHash = handledHash;
      void open(id, false, revision, true);
    } else {
      if (viewedHash || handledHash.startsWith("#agent=")) {
        viewedHash = "";
        if (dialog.open) dialog.close();
      }
      openChatLink(handledHash);
      handledHash = location.hash;
    }
  }

  function display(page, focusItem = null) {
    const scroll = dialog.scrollTop;
    current = page;
    checklistStale = false;
    $("page-link-fallback").hidden = true;
    show("page-link-status", "");
    show("page-export-status", "");
    $("page-heading").textContent = page.title;
    show("page-notice", `Revision ${page.revision} · ${displayDate(page.updated_ms)}${isHistorical() ? " · Read-only revision" : page.agent_owned ? " · Agent page #" + page.id : ""}`);
    $("page-form").hidden = true;
    $("page-read").hidden = false;
    $("page-discuss").hidden = !page.agent_owned || isHistorical();
    const preview = $("page-markdown-preview");
    // Rust renders a restricted Markdown event stream before returning HTML.
    preview.innerHTML = page.html;
    window.renderPageTables(preview, tableViews);
    window.renderPageCharts(preview);
    for (const link of preview.querySelectorAll("a")) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }
    const boxes = checkboxes();
    $("page-checklist-note").hidden = !boxes.length || isHistorical();
    boxes.forEach((box,index) => {
      const parts = [...box.parentElement.childNodes].filter((node) => !["UL", "OL"].includes(node.nodeName));
      const text = parts.map((node) => node.textContent).join("").replace(/\s+/g, " ").trim();
      box.setAttribute("aria-label", [...text].slice(0,120).join("") || ("Checklist item " + (index + 1)));
      box.addEventListener("change", () => void updateChecklist(page, index, box));
    });
    refreshState();
    if (focusItem == null || !boxes[focusItem]) $(isHistorical() ? "page-reload" : "page-edit").focus();
    else {
      boxes[focusItem].focus({preventScroll:true});
      dialog.scrollTop = scroll;
    }
    if (discussing && !isHistorical()) void readTasks();
    if ($("page-revisions").open) void listRevisions();
  }

  async function updateChecklist(page,index,box) {
    if (checking || sending || current !== page || !dialog.open || checklistStale || isHistorical()) return;
    checking = true;
    refreshState();
    try {
      const saved = await api(`/api/pages/${page.id}/checklist`, {revision:page.revision,index,checked:box.checked});
      checking = false;
      if (dialog.open && current === page) {
        setLocation(pageHash(saved.id), true);
        display(saved,index);
        refreshLibraryList();
      }
    } catch (error) {
      if (dialog.open && current === page) {
        box.checked = box.defaultChecked;
        checklistStale = error.status === 409;
        show("page-notice",error.message);
      }
    } finally {
      checking = false;
      refreshState();
      if (dialog.open && current === page) (checklistStale ? $("page-reload") : box).focus({preventScroll:true});
    }
  }

  async function open(id, keepDiscussion = false, revision = null, fromLocation = false) {
    window.pageShare.close();
    const request = ++sequence;
    if (!fromLocation) setLocation(pageHash(id,revision), Boolean(viewedHash));
    const revisionPath = revision != null ? "/revisions/" + revision : "";
    tableViews = new Map();
    missingRevision = null;
    $("page-open-latest").hidden = true;
    if (!keepDiscussion) {
      discussing = false;
      thread = null;
      threadSignature = null;
      ++threadRequest;
      $("page-task-text").value = "";
      show("page-task-error", "");
      $("page-revisions").open = false;
      $("page-revision-list").replaceChildren();
    }
    current = null;
    $("page-heading").textContent = "Page";
    $("page-form").hidden = $("page-read").hidden = true;
    $("page-markdown-preview").replaceChildren();
    show("page-notice", "Loading page…");
    if (!dialog.open) dialog.showModal();
    try {
      const page = await api(`/api/pages/${id}${revisionPath}`);
      if (request === sequence && dialog.open) display(page);
    } catch (error) {
      if (request === sequence && dialog.open) {
        const missing = error.status === 404;
        if (missing && revision != null) {
          missingRevision = id;
          $("page-open-latest").hidden = false;
        }
        show("page-notice", missing ? revision != null ? "That revision is no longer available."
          : "This Page was not found in this workspace." : error.message);
      }
    }
  }

  async function listRevisions() {
    const page = current;
    if (!page || !dialog.open || !$("page-revisions").open) return;
    const requested = ++versionRequest;
    show("page-revision-notice", "Loading revision history…");
    try {
      const result = await api(`/api/pages/${page.id}/revisions`);
      if (page !== current || requested !== versionRequest || !dialog.open) return;
      $("page-revision-list").replaceChildren(...result.items.map((revision) => {
        const row = document.createElement("li");
        const button = document.createElement("button");
        const description = document.createElement("small");
        button.type = "button";
        button.textContent = "Revision " + revision.revision + (revision.revision === result.current_revision ? " · Latest" : "");
        if (revision.revision === page.revision) button.setAttribute("aria-current","true");
        description.textContent = revision.title + " · " + displayDate(revision.updated_ms);
        button.append(description);
        button.addEventListener("click", () => {
          if (!saving && !checking && !sending) void open(page.id,true,
            revision.revision === result.current_revision ? null : revision.revision);
        });
        row.append(button);
        return row;
      }));
      show("page-revision-notice", "");
    } catch (error) {
      if (page === current && requested === versionRequest && dialog.open) show("page-revision-notice", error.message);
    }
  }

  async function restoreRevision() {
    const page = current;
    if (!isHistorical() || checking || checklistStale) return;
    checking = true;
    refreshState();
    try {
      const restored = await api(`/api/pages/${page.id}/revisions/${page.revision}/restore`, {current_revision:page.current_revision});
      checking = false;
      if (dialog.open && current === page) {
        setLocation(pageHash(restored.id), true);
        display(restored);
        show("page-notice", `Revision ${page.revision} restored as revision ${restored.revision}.`);
        refreshLibraryList();
      }
    } catch (error) {
      if (dialog.open && current === page) {
        checklistStale = error.status === 409;
        show("page-notice", error.message);
      }
    } finally { checking = false; refreshState(); }
  }

  function edit(page, text = "") {
    ++sequence;
    current = page;
    if (!page) tableViews = new Map();
    $("page-open-latest").hidden = true;
    $("page-heading").textContent = page ? "Edit page" : "New page";
    $("page-title").value = page?.title || "";
    $("page-markdown").value = page?.markdown || text;
    $("page-read").hidden = true;
    $("page-form").hidden = false;
    show("page-notice", "");
    show("page-error", "");
    if (!dialog.open) dialog.showModal();
    $("page-title").focus();
  }

  function refreshState() {
    if (!dialog.open || !current) return;
    const historical = isHistorical();
    const isOpen = discussing && current.agent_owned && !$("page-read").hidden && !historical;
    dialog.classList.toggle("has-discussion", Boolean(isOpen));
    $("page-discuss").setAttribute("aria-expanded", String(Boolean(isOpen)));
    $("page-discussion").hidden = !isOpen;
    const newer = checklistStale || (isOpen && thread && thread.revision > current.revision);
    $("page-reload").hidden = !newer && !historical;
    $("page-reload").textContent = historical && !newer ? "Back to latest revision" : "Reload latest revision";
    $("page-reload").disabled = sending || checking;
    $("page-edit").hidden = historical;
    $("page-edit").disabled = checking || Boolean(newer);
    $("page-share").hidden = historical;
    $("page-share").disabled = checking || Boolean(newer) || !app.authorized;
    $("page-restore").hidden = !historical;
    $("page-restore").disabled = checking || Boolean(newer) || !app.authorized;
    for (const box of checkboxes()) box.disabled = checking || sending || Boolean(newer) || historical || !app.authorized;
    if (!isOpen) return;
    const owner = thread?.owner;
    const liveOwner = app.online && owner?.core === app.core && app.agents.some((agent) => idOf(agent) === idOf(owner) && live(agent));
    const status = !thread ? "Loading page messages…" : newer ? "A newer revision is available. Reload it before sending."
      : liveOwner ? `Sending to ${owner.name} about revision ${current.revision}.` : "The original agent session is unavailable.";
    if ($("page-discussion-status").textContent !== status) $("page-discussion-status").textContent = status;
    $("page-task-text").disabled = sending;
    $("page-open-agent").hidden = !owner;
    $("page-task-send").disabled = sending || checking || !liveOwner || Boolean(newer)
      || !taskOk($("page-task-text").value) || new TextEncoder().encode($("page-task-text").value).length > 8192;
    $("page-task-send").textContent = sending ? "Sending…" : "Send message";
  }

  async function readTasks() {
    const page = current;
    if (!dialog.open || !page || !discussing || $("page-read").hidden || isHistorical()) return;
    const request = ++threadRequest;
    try {
      const result = await api(`/api/pages/${page.id}/tasks`);
      if (request !== threadRequest || current !== page || !dialog.open || !discussing) return;
      thread = result;
      const signature = JSON.stringify(result.items);
      if (signature !== threadSignature) {
        threadSignature = signature;
        const rows = result.items.map((item) => {
          const row = document.createElement("li");
          const meta = document.createElement("small");
          meta.textContent = `Revision ${item.revision} · ${deliveryLabel[item.state] || item.state}`;
          const body = document.createElement("p");
          body.textContent = item.text;
          row.append(meta, body);
          if (item.detail) {
            const detail = document.createElement("small");
            detail.textContent = item.detail;
            row.append(detail);
          }
          return row;
        });
        $("page-tasks").replaceChildren(...rows);
        $("page-tasks").hidden = !rows.length;
        $("page-tasks").scrollTop = $("page-tasks").scrollHeight;
      }
      refreshState();
    } catch (error) {
      if (request === threadRequest && current === page && dialog.open) $("page-discussion-status").textContent = error.message;
    }
  }

  function dirty() {
    return !$("page-form").hidden
      && ($("page-title").value !== (current?.title || "") || $("page-markdown").value !== (current?.markdown || ""));
  }
  const canClose = () => !saving && !checking && (!dirty() || confirm("Discard the unsaved page edits?"));
  $("page-close").addEventListener("click", () => { if (canClose()) dialog.close(); });
  dialog.addEventListener("cancel", (event) => { if (!canClose()) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    window.pageShare.close();
    ++sequence;
    if (viewedHash && location.hash === viewedHash) setLocation("", true);
    viewedHash = "";
  });
  window.addEventListener("popstate", syncLocation);
  window.addEventListener("hashchange", syncLocation);
  $("page-new").addEventListener("click", () => edit(null));
  $("page-edit").addEventListener("click", () => { if (current) edit(current); });
  $("page-share").addEventListener("click", () => { if (current && !isHistorical()) void window.pageShare.open(current); });
  $("page-discuss").addEventListener("click", () => {
    discussing = !discussing;
    refreshState();
    if (discussing) { void readTasks(); $("page-task-text").focus(); }
  });
  $("page-reload").addEventListener("click", () => { if (current && !sending) void open(current.id, true); });
  $("page-open-latest").addEventListener("click", () => { if (missingRevision) void open(missingRevision); });
  $("page-restore").addEventListener("click", restoreRevision);
  $("page-revisions").addEventListener("toggle", () => { if ($("page-revisions").open) void listRevisions(); });
  $("page-task-text").addEventListener("input", refreshState);
  $("page-open-agent").addEventListener("click", () => {
    const owner = thread?.owner;
    if (!owner) return;
    dialog.close();
    if ($("library").open) $("library").close();
    select(idOf(owner), owner.core);
    $("conversation").focus();
  });
  $("page-task-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if ($("page-task-send").disabled || !current) return;
    const page = current;
    const text = $("page-task-text").value;
    sending = true;
    show("page-task-error", "");
    refreshState();
    try {
      await api(`/api/pages/${page.id}/tasks`, {revision:page.revision, text});
      if (dialog.open && current === page) $("page-task-text").value = "";
    } catch (error) {
      if (dialog.open && current === page) show("page-task-error", error.message);
    } finally {
      sending = false;
      if (dialog.open && current === page) void readTasks();
      refreshState();
    }
  });
  setInterval(readTasks, 2500);
  $("page-cancel-edit").addEventListener("click", () => {
    if (saving) return;
    if (current) display(current);
    else dialog.close();
  });
  $("page-download").addEventListener("click", async () => {
    if (!current) return;
    const page = current;
    const button = $("page-download");
    button.disabled = true;
    try {
      await downloadBlob(`/api/pages/${page.id}/download?revision=${page.revision}`,
        page.title.replace(/[\\/<>:"|?*]/g, "_") + ".md", () => dialog.open && current === page);
    } catch {
      if (dialog.open && current === page) show("page-notice", "Couldn’t download this revision. Reopen the page and try again.");
    } finally {
      button.disabled = false;
    }
  });
  $("page-download-html").addEventListener("click", async () => {
    const page = current;
    if (!page || !app.authorized) return;
    const button = $("page-download-html");
    const visible = () => dialog.open && current === page && app.authorized;
    button.disabled = true;
    show("page-export-status", "Preparing a read-only HTML copy…");
    try {
      await downloadBlob(`/api/pages/${page.id}/download/html?revision=${page.revision}`,
        page.title.replace(/[\\/<>:"|?*]/g, "_") + ".html", visible);
      if (visible()) show("page-export-status", `Downloaded revision ${page.revision}. This copy opens offline without a workspace login.`);
    } catch (error) {
      if (visible()) show("page-export-status", error.status === 409
        ? "This revision is no longer available to download."
        : "Couldn’t download this revision. Try again.");
    } finally {
      button.disabled = false;
    }
  });
  $("page-copy-link").addEventListener("click", async () => {
    const page = current;
    if (!page || !app.authorized) return;
    const url = new URL("/", location.origin);
    url.hash = viewedHash || pageHash(page.id);
    try {
      await navigator.clipboard.writeText(url.href);
      if (dialog.open && current === page) show("page-link-status", "Workspace link copied. It requires workspace access.");
    } catch {
      if (!dialog.open || current !== page) return;
      const field = $("page-link-value");
      field.value = url.href;
      $("page-link-fallback").hidden = false;
      show("page-link-status", "Copy the selected link. It requires workspace access.");
      field.focus();
      field.select();
    }
  });
  $("page-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (saving) return;
    const draft = {title:$("page-title").value, markdown:$("page-markdown").value};
    if (new TextEncoder().encode(draft.markdown).length > 96 * 1024) {
      show("page-error", "Enter up to 96 KiB of Markdown text.");
      return;
    }
    if (current) draft.revision = current.revision;
    saving = $("page-save").disabled = true;
    show("page-error", "");
    try {
      const page = await api(current ? `/api/pages/${current.id}` : "/api/pages", draft);
      if (!app.authorized || !dialog.open) return;
      setLocation(pageHash(page.id), Boolean(viewedHash));
      display(page);
      refreshLibraryList();
    } catch (error) {
      show("page-error", error.message);
    } finally {
      saving = $("page-save").disabled = false;
    }
  });
  window.workspacePages = { open, openVersion:(id,revision) => open(id,false,revision), syncLocation,
    fromReply: (text) => { discussing = false; edit(null, text); }, refreshState };
})();
