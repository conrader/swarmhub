(() => {
  "use strict";
  const byId = (id) => document.getElementById(id);
  const iconPaths = {
    spark: "m12 3 2.1 6.9L21 12l-6.9 2.1L12 21l-2.1-6.9L3 12l6.9-2.1Z",
    layers: "m3 8 9-5 9 5-9 5-9-5Zm0 4 9 5 9-5M3 16l9 5 9-5",
    target: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm0 5a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z",
    terminal: "m4 5 16 0 0 14-16 0Z M7 9l3 3-3 3m5 0h5",
  };
  const ns = "http://www.w3.org/2000/svg";
  const avatars = new WeakMap();
  const photoTargets = new WeakMap();
  const photos = new Map();
  let sequence = 0;
  let latestLoad = null;
  let sessionOptions = null;
  let editing = null;
  let saving = false;
  let creating = false;
  let copying = null;
  let duplicating = false;
  let showingHidden = false;
  const current = () => app.profiles.find((profile) => profile.id === app.selectedProfile);
  const session = () => current()?.sessions.find((item) => app.historyCore === item.core && app.selected === idOf(item));
  const resolve = (item) => item?.core === app.core ? app.agents.find((agent) => idOf(agent) === idOf(item)) : undefined;
  const running = (profile) => profile.sessions.find((item) => resolve(item)?.state === "live");
  const preferred = (profile) => running(profile) || profile.sessions[0];
  const profileFor = (key, core) => app.profiles.find((profile) => profile.sessions.some((item) => item.core === core && idOf(item) === key));

  function discardUnusedPhotos(profiles = []) {
    const held = new Set(profiles.filter((profile) => profile.avatar_key)
      .map((profile) => `/api/profiles/${profile.id}/avatar/${profile.avatar_key}`));
    for (const [path, cached] of photos) {
      if (held.has(path)) continue;
      if (cached.url) URL.revokeObjectURL(cached.url);
      photos.delete(path);
    }
  }

  function photo(path) {
    const previous = photos.get(path);
    if (previous && (!previous.retry || previous.retry > Date.now())) return previous;
    const entry = {};
    photos.set(path, entry);
    entry.ready = fetch(path, {headers: {Authorization: "Bearer " + app.token}}).then(async (response) => {
      if (!response.ok) throw new Error("Avatar unavailable.");
      const data = await response.blob();
      if (photos.get(path) === entry) entry.url = URL.createObjectURL(data);
      return entry.url;
    }).catch(() => {
      entry.retry = Date.now() + 5000;
    });
    return entry;
  }

  function avatar(element, name, style, profile, key) {
    const path = style === "image" && key ? `/api/profiles/${profile}/avatar/${key}` : null;
    if (path) {
      const entry = photo(path);
      if (photoTargets.get(element) === entry) return;
      photoTargets.set(element, entry);
      const apply = (url) => {
        if (!url || photoTargets.get(element) !== entry || photos.get(path) !== entry) return;
        const image = document.createElement("img");
        image.alt = "";
        image.src = url;
        element.replaceChildren(image);
      };
      if (entry.url) {
        apply(entry.url);
        return;
      }
      void entry.ready.then(apply);
    } else {
      photoTargets.delete(element);
    }
    const glyph = iconPaths[style] ? style : Array.from(name)[0]?.toLocaleUpperCase() || "S";
    if (!iconPaths[style]) {
      if (element.textContent !== glyph || element.firstElementChild) element.textContent = glyph;
      return;
    }
    const cached = avatars.get(element);
    if (cached?.glyph === glyph && cached.svg === element.firstElementChild) return;
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.6");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("stroke-linecap", "round");
    const shape = document.createElementNS(ns, "path");
    shape.setAttribute("d", iconPaths[style]);
    svg.append(shape);
    element.replaceChildren(svg);
    avatars.set(element, {glyph, svg});
  }

  async function load() {
    const request = ++sequence;
    let pending = Promise.all([api("/api/profiles"), api("/api/roster-sections")]).then(([profiles, sections]) => {
      if (request === sequence) {
        app.profiles = profiles;
        app.sections = sections;
        discardUnusedPhotos(profiles);
      }
    });
    latestLoad = pending;
    for (;;) {
      await pending;
      if (pending === latestLoad) return;
      pending = latestLoad;
    }
  }

  function open(profile) {
    const item = preferred(profile);
    if (item) select(idOf(item), item.core, profile.id);
    else select(null, null, profile.id);
  }

  function rows() {
    const hasHidden = app.profiles.some((profile) => profile.hidden);
    if (!hasHidden) showingHidden = false;
    byId("show-hidden-agents").hidden = !hasHidden;
    byId("show-hidden-agents").setAttribute("aria-pressed", String(showingHidden));
    byId("show-hidden-agents").textContent = showingHidden ? "Back to main roster" : "Show hidden agents";
    const profiles = app.profiles.filter((profile) => profile.hidden === showingHidden)
      .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.id - a.id);
    const roster = profiles.map((profile) => {
      const item = preferred(profile);
      const terminal = resolve(item);
      const section = app.sections.find((entry) => entry.id === profile.section_id);
      const summary = [profile.pinned ? "Pinned" : "", profile.subtitle,
        section && (showingHidden || profile.pinned) ? section.name : "",
        app.online && terminal ? status(terminal) : item ? "Saved profile" : "Ready to start"].filter(Boolean).join(" · ");
      return {
        key: "profile:" + profile.id, name: profile.name, summary, avatar: profile.avatar,
        avatarKey: profile.avatar_key,
        profileId: profile.id, pinned: profile.pinned, sectionId: section?.id,
        search: [profile.name, profile.runtime_name, profile.subtitle, item?.template || profile.copied_setup?.template, section?.name].join(" "),
        selected: current()?.id === profile.id, open: () => open(profile),
      };
    });
    if (!showingHidden) {
      for (const terminal of app.agents) {
        const key = idOf(terminal);
        if (profileFor(key, app.core)) continue;
        // The roster drops a helper once it has ended; its parent's /helpers list still has it.
        if (terminal.parent && terminal.state !== "live") continue;
        roster.push({
          key, name: title(terminal), summary: (terminal.parent ? `Helper of ${terminal.parent.address} · ` : "") + status(terminal), search: title(terminal) + " " + terminal.template,
          selected: !current() && active() === terminal, open: () => select(key),
        });
      }
    }
    return roster;
  }

  function render() {
    const profile = current();
    window.portableProfiles?.render(profile);
    const picked = session();
    byId("profile-sessions").hidden = !profile;
    byId("profile-edit").hidden = !profile;
    byId("profile-edit").disabled = !app.authorized;
    byId("profile-grok-history").hidden = !profile?.imported_archive;
    byId("profile-duplicate").hidden = !profile;
    byId("profile-duplicate").disabled = !app.authorized;
    byId("profile-draft-instructions").hidden = !profile?.instructions;
    byId("profile-draft-instructions").disabled = byId("task").disabled;
    renderFirstTask();
    if (!profile) return;
    const canStart = !running(profile) || !app.online;
    byId("profile-start").hidden = !canStart;
    byId("profile-start").disabled = !available();
    byId("profile-start").textContent = profile.sessions.length ? "Start new session" : "Start first session";
    byId("profile-session").hidden = byId("profile-session-label").hidden = !profile.sessions.length;
    const sessions = profile.sessions.map((item) => ({
      key: item.core + "/" + idOf(item),
      label: (app.online && resolve(item)?.state === "live" ? "Running · " : "")
        + displayDate(item.created_ms) + " · " + item.address + " · " + item.template,
    }));
    const signature = JSON.stringify(sessions);
    const chooser = byId("profile-session");
    if (signature !== sessionOptions) {
      sessionOptions = signature;
      chooser.replaceChildren(...sessions.map(({key, label}) => new Option(label, key)));
    }
    chooser.value = picked ? picked.core + "/" + idOf(picked) : "";
  }

  function firstTask(id) {
    return readTabDraft("profile-first", id)?.text ?? app.linkedFirstTasks.get(id) ?? "";
  }

  function saveFirstTask(id, text) {
    app.linkedFirstTasks.delete(id);
    saveTabDraft("profile-first", id, text ? {text} : null);
  }

  function renderFirstTask() {
    const profile = current();
    const composer = byId("profile-first-compose");
    const field = byId("profile-first-task");
    composer.hidden = !app.authorized || !profile || profile.sessions.length !== 0;
    const text = composer.hidden ? "" : firstTask(profile.id);
    if (field.value !== text) field.value = text;
    const tooLong = text.length > 0 && new TextEncoder().encode(text).length > 16384;
    const canLaunch = available();
    byId("profile-first-review").disabled = composer.hidden || !canLaunch || !taskOk(text);
    byId("profile-first-help").textContent = tooLong ? "Use up to 16 KiB of plain text."
      : canLaunch ? "You’ll review the runtime before sending."
      : "Your draft stays in this tab. A Herdr template is needed to send it.";
  }

  byId("profile-first-task").addEventListener("input", (event) => {
    const profile = current();
    if (!app.authorized || !profile || profile.sessions.length) return;
    saveFirstTask(profile.id, event.target.value);
    renderFirstTask();
  });
  byId("profile-first-compose").addEventListener("submit", (event) => {
    event.preventDefault();
    const profile = current();
    if (!app.authorized || !profile || profile.sessions.length || !taskOk(firstTask(profile.id))) return;
    openLaunch(profile);
  });

  function createProfile() {
    if (!app.authorized || creating) return;
    const dialog = byId("profile-create-dialog");
    const field = byId("profile-create-name");
    field.value = "";
    show("profile-create-error", "");
    dialog.showModal();
  }

  byId("profile-new").addEventListener("click", createProfile);
  byId("profile-first").addEventListener("click", createProfile);
  byId("profile-create-close").addEventListener("click", () => {
    if (!creating) byId("profile-create-dialog").close();
  });
  byId("profile-create-dialog").addEventListener("cancel", (event) => { if (creating) event.preventDefault(); });
  byId("profile-create-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!app.authorized || creating) return;
    const field = byId("profile-create-name");
    const button = byId("profile-create-save");
    const close = byId("profile-create-close");
    const name = field.value;
    const token = app.token;
    if (!name.trim() || Array.from(name.trim()).length > 60) {
      show("profile-create-error", "Enter an agent name up to 60 characters.");
      field.focus();
      return;
    }
    creating = field.disabled = button.disabled = close.disabled = true;
    button.textContent = "Creating…";
    show("profile-create-error", "");
    try {
      const profile = await api("/api/profiles", {name});
      if (!app.authorized || app.token !== token) return;
      ++sequence;
      app.profiles = [profile, ...app.profiles.filter((other) => other.id !== profile.id)];
      showingHidden = false;
      byId("search").value = "";
      byId("profile-create-dialog").close();
      open(profile);
      byId("profile-first-task").focus();
    } catch (error) {
      show("profile-create-error", error.message);
    } finally {
      creating = field.disabled = button.disabled = close.disabled = false;
      button.textContent = "Create agent";
      if (byId("profile-create-dialog").open) field.focus();
    }
  });

  byId("show-hidden-agents").addEventListener("click", () => { showingHidden = !showingHidden; renderRoster(); });
  byId("profile-session").addEventListener("change", (event) => {
    const profile = current();
    const item = profile?.sessions.find((item) => event.target.value === item.core + "/" + idOf(item));
    if (item) select(idOf(item), item.core, profile.id);
    event.target.focus();
  });
  byId("profile-start").addEventListener("click", () => { if (current()) openLaunch(current()); });
  byId("profile-grok-history").addEventListener("click", () => {
    const archive = current()?.imported_archive;
    if (archive) {
      if (!byId("library").open) byId("library").showModal();
      showArchive(archive);
    }
  });
  function editProfile(remember = "") {
    editing = current();
    if (!editing) return;
    byId("profile-name").value = editing.name;
    byId("profile-subtitle").value = editing.subtitle;
    byId("profile-avatar").value = editing.avatar;
    window.avatarUpload.reset(editing);
    byId("profile-pin").checked = editing.pinned;
    byId("profile-hide").checked = editing.hidden;
    const instructions = byId("profile-instructions");
    instructions.value = [editing.instructions, remember.trim()].filter(Boolean).join("\n\n");
    show("profile-error", "");
    byId("profile-dialog").showModal();
    if (remember) {
      instructions.focus();
      instructions.setSelectionRange(editing.instructions.length, instructions.value.length);
    }
  }
  byId("profile-edit").addEventListener("click", () => editProfile());
  byId("profile-duplicate").addEventListener("click", () => {
    copying = current();
    if (!copying || !app.authorized) return;
    byId("duplicate-name").value = Array.from(copying.name).slice(0, 55).join("").trimEnd() + " copy";
    show("duplicate-error", "");
    const dialog = byId("duplicate-dialog");
    dialog.showModal();
    byId("duplicate-name").select();
  });
  byId("duplicate-close").addEventListener("click", () => { if (!duplicating) byId("duplicate-dialog").close(); });
  byId("duplicate-dialog").addEventListener("cancel", (event) => { if (duplicating) event.preventDefault(); });
  byId("duplicate-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!copying || duplicating) return;
    duplicating = byId("duplicate-save").disabled = true;
    show("duplicate-error", "");
    try {
      const copy = await api(`/api/profiles/${copying.id}/duplicate`, {
        name: byId("duplicate-name").value, revision: copying.revision,
      });
      ++sequence;
      app.profiles = [copy, ...app.profiles.filter((profile) => profile.id !== copy.id)];
      showingHidden = false;
      byId("search").value = "";
      byId("duplicate-dialog").close();
      open(copy);
      byId("conversation").focus();
    } catch (error) {
      show("duplicate-error", error.message);
      if (error.status === 409) void refresh();
    } finally {
      duplicating = byId("duplicate-save").disabled = false;
    }
  });
  byId("profile-draft-instructions").addEventListener("click", () => {
    const profile = current();
    const task = byId("task");
    if (!profile?.instructions || task.disabled) return;
    const combined = instructionMessage(task.value, profile.instructions);
    if (!taskOk(combined)) {
      show("composer-error", "The draft and standing instructions together must fit within 16 KiB.");
      return;
    }
    task.value = combined;
    task.dispatchEvent(new Event("input"));
    task.focus();
    show("composer-error", "");
    show("notice", "Standing instructions added to your draft.");
  });
  byId("profile-close").addEventListener("click", () => { if (!saving) byId("profile-dialog").close(); });
  byId("profile-dialog").addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  byId("profile-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!editing || saving) return;
    if (new TextEncoder().encode(byId("profile-instructions").value).length > 6144) {
      show("profile-error", "Use up to 6 KiB of plain text for standing instructions.");
      return;
    }
    saving = byId("profile-save").disabled = true;
    show("profile-error", "");
    try {
      const avatar = byId("profile-avatar").value;
      const avatarPng = await window.avatarUpload.capture();
      await api(`/api/profiles/${editing.id}`, {
        name: byId("profile-name").value, subtitle: byId("profile-subtitle").value,
        avatar, avatar_png: avatarPng, pinned: byId("profile-pin").checked,
        hidden: byId("profile-hide").checked, revision: editing.revision,
        instructions: byId("profile-instructions").value,
      });
      await load();
      byId("profile-dialog").close();
      renderState();
    } catch (error) {
      show("profile-error", error.message);
      if (error.status === 409) void refresh();
    } finally {
      saving = byId("profile-save").disabled = false;
    }
  });
  async function openById(id) {
    if (!app.profiles.some((profile) => profile.id === id)) await load();
    if (!openLoaded(id)) throw new Error("This agent profile is no longer available.");
  }

  function openLoaded(id) {
    const profile = app.profiles.find((profile) => profile.id === id);
    if (!profile) return false;
    open(profile);
    $("conversation").focus();
    return true;
  }
  function acceptImport(profile) {
    ++sequence;
    app.profiles = [profile, ...app.profiles.filter((other) => other.id !== profile.id)];
    showingHidden = false;
    byId("search").value = "";
    open(profile);
    byId("profile-first-task").focus();
  }
  window.agentProfiles = { avatar, discardUnusedPhotos, current, editProfile, firstTask, load, openById, openLoaded,
    acceptImport, profileFor, render, renderFirstTask, rows, saveFirstTask, session, isShowingHidden: () => showingHidden };
})();
