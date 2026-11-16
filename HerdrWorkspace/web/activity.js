(() => {
  "use strict";
  const dialog = $("activity-dialog");
  const opener = $("activity-open");
  const list = $("activity-items");
  const readAll = $("activity-read-all");
  const older = $("activity-older");
  const filter = $("activity-unread-only");
  const direct = new Map(), groups = new Map(), seen = new Map();
  const labels = {reply:"Agent reply", group:"Group reply", file:"Saved file", page:"New Page"};
  const session = (core, key) => JSON.stringify([core,key]);
  let count = 0, summaryRequest = null, summarySeq = 0, view = null, updating = false;

  function badge(element, unread) {
    if (!element) return;
    const label = unread > 99 ? "99+" : unread ? String(unread) : "";
    if (element.textContent !== label) element.textContent = label;
    element.hidden = !unread;
    if (unread) element.setAttribute("aria-label", unread + " unread");
    else element.removeAttribute("aria-label");
  }

  function agentCount(agent) {
    if (!agent) return 0;
    if (!agent.profileId) return direct.get(session(app.core, agent.key)) || 0;
    return (app.profiles.find((profile) => profile.id === agent.profileId)?.sessions || [])
      .reduce((sum, model) => sum + (direct.get(session(model.core, idOf(model))) || 0), 0);
  }

  function applySummary(rows) {
    direct.clear(); groups.clear();
    count = 0;
    for (const row of rows) {
      count += row.count;
      if (row.group_id !== null) groups.set(row.group_id, row.count);
      else direct.set(session(row.core, row.address + "/" + row.created_ms), row.count);
    }
    badge($("activity-count"), count);
    opener.setAttribute("aria-label", count ? "Activity, " + count + " unread" : "Activity");
    readAll.disabled = !view?.top || !count || updating;
    renderRoster();
  }

  async function fetchSummary() {
    const sequence = ++summarySeq;
    try {
      const rows = await api("/api/activity/unread");
      if (sequence === summarySeq && app.authorized) applySummary(rows);
    } catch {
      // A transient network error should not clear the last known unread count.
    }
  }

  async function mark(body) {
    const sequence = ++summarySeq;
    const rows = await api("/api/activity/read", body);
    if (sequence === summarySeq && app.authorized) applySummary(rows);
  }

  function see(scope, through) {
    if (!app.authorized || !through || document.hidden || !document.hasFocus() || document.querySelector("dialog[open]")
      || (matchMedia("(max-width:640px)").matches && $("workspace").dataset.mobileView === "roster")) return;
    const key = JSON.stringify(scope);
    if ((seen.get(key) || 0) >= through) return;
    seen.set(key, through);
    void mark({...scope, through}).catch(() => {
      if (seen.get(key) === through) seen.delete(key);
    });
  }

  async function visit(entry, button = null) {
    if (!app.authorized) return;
    if (button) button.disabled = true;
    try {
      if (entry.unread) await mark({kind:"item",id:entry.id});
      if (button && !dialog.open) return;
      if (dialog.open) dialog.close();
      if (entry.group_id !== null) await window.groupWorkspace.openMessage(entry.group_id, entry.message);
      else {
        if (!$("library").open) $("library").showModal();
        const agent = entry.name || window.agentProfiles.profileFor(entry.address + "/" + entry.created_ms, entry.core)?.name || "Saved conversation";
        showArchive({...entry,agent}, entry.message);
      }
    } catch (error) {
      show(dialog.open ? "activity-status" : "notice", error.message);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function row(entry) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.classList.toggle("activity-unread", entry.unread);
    button.dataset.activityId = entry.id;
    const name = document.createElement("strong");
    const detail = document.createElement("small");
    const excerpt = document.createElement("small");
    name.textContent = entry.group_name ? entry.group_name + " · " + entry.name : entry.name;
    detail.textContent = [entry.unread ? "Unread" : "", labels[entry.kind], displayDate(entry.at_ms)].filter(Boolean).join(" · ");
    excerpt.className = "activity-excerpt";
    excerpt.textContent = entry.excerpt;
    button.append(name, detail);
    if (entry.excerpt) button.append(excerpt);
    button.addEventListener("click", () => void visit(entry, button));
    li.append(button);
    return li;
  }

  function note(message) {
    if ($("activity-status").textContent !== message) show("activity-status", message);
  }

  async function load(previous = false) {
    const current = view;
    if (!current || current.loading || (previous && !current.before)) return;
    current.loading = true;
    older.disabled = true;
    try {
      const query = new URLSearchParams({unread:String(filter.checked)});
      if (previous) query.set("before", current.before);
      const page = await api("/api/activity?" + query);
      if (current !== view) return;
      const signature = JSON.stringify(page.items);
      if (previous) {
        list.append(...page.items.map(row));
        current.paged = true;
      } else if (signature !== current.signature) {
        const focus = document.activeElement?.dataset?.activityId;
        list.replaceChildren(...page.items.map(row));
        if (focus) [...list.querySelectorAll("button")].find((button) => button.dataset.activityId === focus)?.focus({preventScroll:true});
        current.signature = signature;
      }
      if (!previous) current.top = page.items[0]?.id;
      current.before = page.before;
      older.hidden = !page.before;
      note(list.childElementCount ? "" : filter.checked ? "No unread activity." : "No replies or results yet.");
    } catch (error) {
      if (current === view) note(error.message);
    } finally {
      current.loading = false;
      if (current === view) {
        older.disabled = false;
        readAll.disabled = !current.top || !count || updating;
      }
    }
  }

  function reset() {
    view = {};
    list.replaceChildren();
    older.hidden = true;
    readAll.disabled = true;
    note("Loading activity…");
    void load();
  }

  function refresh() {
    if (!app.authorized) {
      if (count || seen.size) {
        ++summarySeq;
        seen.clear();
        applySummary([]);
      }
      return;
    }
    if (document.hidden) return;
    if (!summaryRequest) summaryRequest = fetchSummary().finally(() => { summaryRequest = null; });
    if (dialog.open && !view?.paged && !updating) void load();
    return summaryRequest;
  }

  function open() {
    if (!app.authorized || dialog.open) return;
    dialog.showModal();
    reset();
  }
  opener.addEventListener("click", open);
  $("activity-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { if (!dialog.open) view = null; });
  filter.addEventListener("change", reset);
  older.addEventListener("click", () => void load(true));
  readAll.addEventListener("click", async () => {
    const through = view?.top;
    if (!through || updating) return;
    updating = readAll.disabled = true;
    try {
      await mark({kind:"through",id:through});
      if (dialog.open) reset();
    } catch (error) {
      if (dialog.open) note(error.message);
    } finally {
      updating = false;
      readAll.disabled = !view?.top || !count;
    }
  });

  window.workspaceActivity = {badge,agentCount,groupCount:(id) => groups.get(id) || 0,see,refresh,open,visit};
})();
