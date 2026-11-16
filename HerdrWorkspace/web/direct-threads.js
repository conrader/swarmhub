(() => {
  "use strict";
  const dialog = $("direct-thread");
  const close = $("direct-thread-close");
  const feed = $("direct-thread-feed");
  const root = $("direct-thread-root");
  const items = $("direct-thread-items");
  const form = $("direct-thread-composer");
  const draft = $("direct-thread-text");
  const send = $("direct-thread-send");
  const older = $("direct-thread-older");
  const drafts = new Map();
  const limit = 14 * 1024;
  let view = null;

  function recipient() {
    if (!view || !app.online || app.core !== view.core) return null;
    return app.agents.find((agent) => idOf(agent) === view.key && live(agent));
  }

  function textSize() { return new TextEncoder().encode(draft.value).length; }

  function render() {
    if (!view || !dialog.open) return;
    const agent = recipient();
    form.hidden = !agent || !view.loaded;
    draft.disabled = app.busy || agent?.status?.state === "blocked";
    draft.setCustomValidity(textSize() > limit ? "Keep the reply at 14 KiB or less to leave room for the quote." : "");
    send.disabled = draft.disabled || !draft.value.trim() || !draft.validity.valid;
    send.textContent = view.sending ? "Sending…" : "Send reply";
    older.disabled = view.loading || view.sending;
    older.hidden = !view.before;
    close.disabled = view.sending;
  }

  function note(text) {
    const current = $("direct-thread-notice");
    const value = view?.sendError || text;
    if (current.textContent !== value) show("direct-thread-notice", value);
  }

  function originalCard(entry, thread) {
    const card = historyRow(entry, false, false, thread.path);
    const length = Array.from(entry.text.slice(0, 940));
    const lines = entry.text.split("\n", 5);
    if (length.length <= 220 && lines.length <= 4) return card;
    const original = card.querySelector(":scope > .reply-body");
    const preview = document.createElement("p");
    preview.textContent = Array.from(lines.slice(0, 4).join("\n")).slice(0, 220).join("") + "…";
    const details = document.createElement("details");
    details.className = "thread-original-details";
    details.open = Boolean(root.querySelector("details[open]"));
    const toggle = document.createElement("summary");
    toggle.textContent = details.open ? "Show less" : "Read full original";
    details.append(toggle);
    original.replaceWith(preview, details);
    details.append(original);
    details.addEventListener("toggle", () => {
      preview.hidden = details.open;
      toggle.textContent = details.open ? "Show less" : "Read full original";
    });
    preview.hidden = details.open;
    return card;
  }

  async function read(previous = false) {
    const thread = view;
    if (!thread || thread.loading) return;
    thread.loading = true;
    render();
    try {
      const page = await api(thread.route + (previous ? "?before=" + thread.before : ""));
      if (thread !== view) return;
      const was = feed.scrollHeight;
      const towardEnd = thread.followLatest || (thread.loaded && was - feed.scrollTop - feed.clientHeight < 24);
      const rootSignature = JSON.stringify(page.original);
      if (!previous && rootSignature !== thread.rootSignature) {
        root.replaceChildren(originalCard(page.original, thread));
        thread.rootSignature = rootSignature;
      }
      if (previous || thread.paged) {
        const combined = new Map(thread.entries.map((item) => [item.id,item]));
        for (const row of page.items) combined.set(row.id,row);
        thread.entries = [...combined.values()].sort((a,b) => a.id - b.id);
      } else thread.entries = page.items;
      const signature = JSON.stringify(thread.entries);
      if (signature !== thread.signature) {
        const rows = thread.entries.map((entry) => historyRow(entry, false, false, thread.path));
        window.messageReactions.replaceRows(items, rows);
        thread.signature = signature;
        if (previous) feed.scrollTop += feed.scrollHeight - was;
        else if (towardEnd) feed.scrollTop = feed.scrollHeight;
      }
      thread.loaded = true;
      thread.followLatest = false;
      if (!thread.paged || previous) thread.before = page.before;
      if (previous) thread.paged = true;
      note(items.childElementCount ? "" : "No follow-ups yet.");
    } catch (error) {
      if (thread === view) note(error.message);
    } finally {
      thread.loading = false;
      if (thread === view) render();
    }
  }

  function open(session, anchor, trigger) {
    if (dialog.open) return;
    const route = session.path + "/threads/" + anchor;
    const thread = view = { ...session, route, anchor, trigger, loaded:false, loading:false, sending:false, before:null,
      entries:[], paged:false, container:trigger.closest("#tasks,#archive-items") };
    $("direct-thread-agent").textContent = session.name;
    draft.value = drafts.get(route) || "";
    root.replaceChildren();
    items.replaceChildren();
    form.hidden = older.hidden = true;
    close.disabled = false;
    note("Loading thread…");
    dialog.showModal();
    close.focus();
    feed.scrollTop = 0;
    void read();
    thread.timer = setInterval(() => {
      if (view === thread && dialog.open && !document.hidden) void read();
    }, 1600);
  }

  function button(session, entry) {
    const anchor = entry.reply_to?.id ?? entry.id;
    const control = document.createElement("button");
    control.type = "button";
    control.className = "thread-open";
    control.dataset.threadRoute = session.path + "/threads/" + anchor;
    control.setAttribute("aria-haspopup", "dialog");
    control.textContent = entry.followups ? "Thread · " + entry.followups : "Open thread";
    if (entry.followups) control.setAttribute("aria-label", "Open thread, " + entry.followups + (entry.followups === 1 ? " follow-up" : " follow-ups"));
    control.addEventListener("click", () => open(session, anchor, control));
    return control;
  }

  close.addEventListener("click", () => { if (!view?.sending) dialog.close(); });
  older.addEventListener("click", () => { if (view?.before) void read(true); });
  dialog.addEventListener("cancel", (event) => { if (view?.sending) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open || !view) return;
    const { route, trigger, container, timer } = view;
    clearInterval(timer);
    view = null;
    const replacement = trigger.isConnected ? trigger : [...(container?.querySelectorAll(".thread-open") || [])]
      .find((candidate) => candidate.dataset.threadRoute === route);
    replacement?.focus({preventScroll:true});
  });
  draft.addEventListener("input", () => {
    if (view) drafts.set(view.route, draft.value);
    render();
    if (textSize() > limit) draft.reportValidity();
  });
  draft.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter" && !send.disabled) {
      event.preventDefault();
      form.requestSubmit();
    }
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const thread = view;
    if (!thread || !recipient() || send.disabled || app.busy) return;
    app.busy = thread.sending = true;
    thread.sendError = "";
    note("");
    renderState();
    try {
      await api("/api/agents/" + thread.key + "/messages", {text:draft.value, reply_to:{core:thread.core, id:thread.anchor}});
      drafts.delete(thread.route);
      draft.value = "";
      thread.followLatest = true;
      await read();
      if (app.historyCore === thread.core && app.selected === thread.key) void readHistory();
    } catch (error) {
      thread.sendError = error.message;
      note("");
    } finally {
      app.busy = thread.sending = false;
      renderState();
      if (dialog.open && !form.hidden && !draft.disabled) draft.focus();
    }
  });

  window.directThreads = {button, render};
})();
