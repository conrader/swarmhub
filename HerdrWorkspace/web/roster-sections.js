(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const folded = new Set();
  let moving = null;
  let editing = null;
  let saving = false;
  let moveTrigger = null;

  function buckets(rows, filter) {
    if (!app.sections.length || window.agentProfiles.isShowingHidden()) {
      return [{ key: null, name: "", rows }];
    }
    const pinned = { key: "pinned", name: "Pinned", rows: [] };
    const other = { key: "unsectioned", name: "Unsectioned", rows: [] };
    const sections = new Map(app.sections.map(({ id, name }) => [id, { key: "section-" + id, name, rows: [] }]));
    for (const row of rows) {
      (row.pinned ? pinned : sections.get(row.sectionId) || other).rows.push(row);
    }
    return [pinned, ...sections.values(), other].filter(({key, rows}) =>
      rows.length || (!filter && key.startsWith("section-")));
  }

  function bucketView(bucket, element, filter) {
    if (!element) {
      element = document.createElement("section");
      element.className = "roster-bucket";
      element.dataset.bucket = bucket.key;
      const title = document.createElement("button");
      title.type = "button";
      title.className = "roster-bucket-title";
      const count = document.createElement("small");
      count.setAttribute("aria-hidden", "true");
      title.append(document.createElement("span"), count);
      const list = document.createElement("div");
      list.className = "roster-bucket-list";
      list.id = "roster-list-" + bucket.key;
      title.setAttribute("aria-controls", list.id);
      title.addEventListener("click", () => {
        if (!folded.delete(bucket.key)) folded.add(bucket.key);
        syncExpansion(element, false);
      });
      element.append(title, list);
    }
    const [title, list] = element.children;
    title.firstChild.textContent = bucket.name;
    title.lastChild.textContent = String(bucket.rows.length);
    title.disabled = Boolean(filter || !bucket.rows.length);
    syncExpansion(element, Boolean(filter || !bucket.rows.length));
    return { element, list };
  }

  function syncExpansion(element, forceOpen) {
    const [title, list] = element.children;
    const open = forceOpen || !folded.has(element.dataset.bucket);
    title.setAttribute("aria-expanded", String(open));
    list.hidden = !open;
  }

  function render() {
    $("sections-open").disabled = !app.authorized;
    $("profile-move-section").hidden = !window.agentProfiles.current();
    $("profile-move-section").disabled = !app.authorized;
  }

  function openMove(profileId, trigger) {
    moving = app.profiles.find((profile) => profile.id === profileId);
    if (!app.authorized || !moving || $("move-section-dialog").open) return;
    moveTrigger = trigger;
    $("move-section-agent").textContent = moving.name;
    $("move-section-destination").replaceChildren(new Option("Unsectioned", ""),
      ...app.sections.map(({name, id}) => new Option(name, String(id))),
      new Option("Create a new section…", "new"));
    $("move-section-destination").value = app.sections.some(({id}) => id === moving.section_id)
      ? String(moving.section_id) : "";
    $("move-section-name").value = "";
    show("move-section-error", "");
    drawDestination();
    $("move-section-dialog").showModal();
    $("move-section-destination").focus();
  }

  function drawDestination() {
    const creating = $("move-section-destination").value === "new";
    $("move-section-name-field").hidden = !creating;
    $("move-section-name").required = creating;
  }

  function fillSections() {
    const entries = app.sections.map((section) => {
      const row = document.createElement("li");
      row.dataset.section = section.id;
      const label = document.createElement("span");
      label.textContent = section.name;
      const actions = document.createElement("div");
      for (const action of ["Rename", "Remove"]) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = action;
        button.setAttribute("aria-label", action + " " + section.name);
        button.addEventListener("click", () => {
          if (saving) return;
          editing = { section, action: action.toLowerCase() };
          drawSectionForm();
        });
        actions.append(button);
      }
      row.append(label, actions);
      return row;
    });
    $("sections-list").replaceChildren(...entries);
    $("sections-empty").hidden = Boolean(entries.length);
  }

  function drawSectionForm(focus = true) {
    const removing = editing?.action === "remove";
    $("section-name-field").hidden = removing;
    $("section-name").required = !removing;
    $("section-name").value = editing?.section.name || "";
    show("section-remove-help", removing ? `Remove “${editing.section.name}”? Its agents will move to Unsectioned.` : "");
    $("section-reset").hidden = !editing;
    $("section-submit").textContent = removing ? "Remove section" : editing ? "Save name" : "Create section";
    show("section-error", "");
    if (focus) $(removing ? "section-submit" : "section-name").focus();
  }

  async function updateRoster() {
    await window.agentProfiles.load();
    renderState();
  }

  $("sections-open").addEventListener("click", () => {
    editing = null;
    fillSections();
    drawSectionForm(false);
    $("sections-dialog").showModal();
    $("section-name").focus();
  });
  $("section-reset").addEventListener("click", () => { if (!saving) { editing = null; drawSectionForm(); } });
  $("profile-move-section").addEventListener("click", (event) => openMove(app.selectedProfile, event.currentTarget));
  $("move-section-destination").addEventListener("change", drawDestination);
  $("move-section-dialog").addEventListener("close", () => {
    if (moveTrigger?.isConnected && moveTrigger.dataset.key && !moveTrigger.closest("[hidden]") && moveTrigger.offsetParent) {
      moveTrigger.focus();
    }
    moveTrigger = null;
  });
  for (const [dialog, close] of [["sections-dialog","sections-close"],["move-section-dialog","move-section-close"]]) {
    $(close).addEventListener("click", () => { if (!saving) $(dialog).close(); });
    $(dialog).addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  }
  $("section-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (saving) return;
    const name = $("section-name").value;
    const path = "/api/roster-sections" + (editing ? "/" + editing.section.id : "");
    const data = editing ? {action: editing.action, revision: editing.section.revision,
      ...(editing.action === "rename" ? {name} : {})} : {name};
    saving = $("section-submit").disabled = true;
    show("section-error", "");
    try {
      await api(path, data);
      await updateRoster();
      editing = null;
      fillSections();
      drawSectionForm();
    } catch (error) {
      show("section-error", error.message);
      if (error.status === 409 || error.status === 404) {
        await updateRoster().catch(() => {});
        fillSections();
      }
    } finally {
      saving = $("section-submit").disabled = false;
    }
  });
  $("move-section-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (saving || !moving) return;
    const value = $("move-section-destination").value;
    const dest = value === "new" ? {destination: "new", name: $("move-section-name").value}
      : value ? {destination: "existing", id: Number(value)} : {destination: "unsectioned"};
    saving = $("move-section-submit").disabled = true;
    show("move-section-error", "");
    try {
      await api(`/api/profiles/${moving.id}/section`, {...dest, revision: moving.revision});
      if (value) folded.delete("section-" + value);
      await updateRoster();
      $("move-section-dialog").close();
    } catch (error) {
      show("move-section-error", error.message);
      if (error.status === 409) void updateRoster().catch(() => {});
    } finally {
      saving = $("move-section-submit").disabled = false;
    }
  });
  window.rosterSections = {bucketView, buckets, openMove, render};
})();
