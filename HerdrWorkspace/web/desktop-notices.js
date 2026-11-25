(() => {
  "use strict";
  const toggle = $("desktop-notices-toggle");
  const status = $("desktop-notices-status");
  const agentOption = $("profile-desktop-alerts");
  const agentEnabled = $("profile-desktop-alerts-enabled");
  const preferenceKey = "swarmhub-desktop-notices-v1";
  const checkpointKey = preferenceKey + "-checkpoint";
  const notices = new Map();
  let changing = false, polling = false, ready = false, error = "";

  function stored(key) {
    try { return JSON.parse(localStorage.getItem(key)); } catch { return null; }
  }

  function save(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); return true; }
    catch { return false; }
  }

  function preferences() {
    const saved = stored(preferenceKey);
    return { enabled: saved?.enabled === true, revision: saved?.revision || "",
      muted: Array.isArray(saved?.muted) ? saved.muted : [] };
  }

  const supported = () => isSecureContext && typeof Notification === "function"
    && typeof navigator.locks?.request === "function";
  const granted = () => supported() && Notification.permission === "granted";

  function render() {
    const pref = preferences();
    const profile = window.agentProfiles.current();
    const available = supported();
    agentOption.hidden = !profile || !available;
    if (profile) agentEnabled.checked = !pref.muted.includes(profile.id);
    toggle.textContent = pref.enabled ? "Turn off desktop notifications" : "Enable desktop notifications";
    toggle.disabled = !app.authorized || changing || !available || (!pref.enabled && Notification.permission === "denied");
    const text = !available ? "Desktop notifications aren’t available in this browser."
      : error ? error
      : Notification.permission === "denied" ? "Notifications are blocked in this browser’s site settings."
      : changing || (pref.enabled && granted() && !ready) ? "Starting desktop notifications…"
      : pref.enabled && granted() ? "Desktop notifications are on. Keep this tab open."
      : "Desktop notifications are off.";
    if (status.textContent !== text) status.textContent = text;
  }

  function closeNotices() {
    for (const notice of notices.values()) notice.close();
    notices.clear();
  }

  function isFocusedConversation(item) {
    if (document.hidden || !document.hasFocus() || document.querySelector("dialog[open]")
      || (matchMedia("(max-width:640px)").matches && $("workspace").dataset.mobileView === "roster")) return false;
    if (item.group_id != null) {
      return Number(document.querySelector('#groups [aria-current="true"]')?.dataset.group) === item.group_id;
    }
    return item.core === app.historyCore && item.address + "/" + item.created_ms === app.selected;
  }

  function notify(tag, body, visit) {
    try {
      const notice = new Notification("SwarmHub", {body,tag:"swarmhub-" + tag});
      notices.get(tag)?.close();
      notices.set(tag, notice);
      notice.onclick = (event) => {
        event.preventDefault();
        window.focus();
        notice.close();
        if (app.authorized) visit();
      };
      notice.onclose = () => { if (notices.get(tag) === notice) notices.delete(tag); };
      notice.onerror = () => {
        error = "This browser couldn’t show a desktop notification. Activity is still available here.";
        render();
      };
    } catch {
      error = "This browser couldn’t show a desktop notification. Activity is still available here.";
    }
  }

  function attentionItems(inbox) {
    return [
      ...inbox.approvals.map((item) => ({key:"approval:" + item.id, terminal:item.terminal})),
      ...(inbox.ci_failures || []).filter((item) => item.notifications).map((item) => {
        const agent = app.agents.find((agent) => agent.name === item.agent_name && live(agent));
        return {key:"ci:" + item.id, terminal:agent && [app.core, agent.address, agent.created_ms]};
      }),
      ...inbox.requests.map((item) => ({key:"group:" + item.group + "/" + item.id})),
      ...(inbox.webhook_reviews || []).map((item) => ({key:"webhook:" + item.routine + "/" + item.id, terminal:item.terminal})),
    ];
  }

  async function pulse() {
    const before = preferences();
    if (!before.enabled || !granted() || !app.authorized) return;
    const saved = stored(checkpointKey);
    const was = saved?.revision === before.revision && Date.now() - saved.at < 120_000 ? saved : {};
    const after = Number.isSafeInteger(was.cursor) ? "?after=" + was.cursor : "";
    const [activity, attention] = await Promise.allSettled([
      api("/api/activity/signals" + after),
      api("/api/attention"),
    ]);
    const pref = preferences();
    if (!pref.enabled || pref.revision !== before.revision || !app.authorized || !granted()) return;
    if (activity.status !== "fulfilled" && attention.status !== "fulfilled") return;
    const activityItems = activity.status === "fulfilled" ? activity.value.items : [];
    const pending = attention.status === "fulfilled" ? attentionItems(attention.value) : null;
    if (!save(checkpointKey, {revision:pref.revision, at:Date.now(),
      cursor:activity.status === "fulfilled" ? activity.value.cursor : was.cursor,
      pending:pending ? pending.map((item) => item.key) : was.pending})) {
      error = "This browser couldn’t save notification settings.";
      return;
    }
    ready = true;
    const visible = activityItems.filter((item) => !pref.muted.includes(item.profile) && !isFocusedConversation(item));
    if (visible.length) {
      notify("activity", visible.length === 1 ? "A new reply or result is ready." : "New replies or results are ready.", () => {
        if (visible.length === 1) void window.workspaceActivity.visit({...visible[0],unread:true});
        else window.workspaceActivity.open();
      });
    }
    if (pending && Array.isArray(was.pending)) {
      const previous = new Set(was.pending);
      if (pending.some((item) => {
        if (previous.has(item.key)) return false;
        const [core,address,created] = item.terminal || [];
        const profile = core && window.agentProfiles.profileFor(address + "/" + created, core);
        return !profile || !pref.muted.includes(profile.id);
      })) notify("attention", "A request needs your attention.", () => $("attention-open").click());
    }
  }

  async function tick() {
    if (!app.authorized || !preferences().enabled || !granted() || polling) return;
    polling = true;
    try {
      await navigator.locks.request(preferenceKey, {ifAvailable:true}, async (lock) => {
        if (lock) await pulse();
        else if (stored(checkpointKey)?.revision === preferences().revision) ready = true;
      });
    } catch {
      error = "Desktop notifications are temporarily unavailable.";
    } finally {
      polling = false;
      render();
    }
  }

  toggle.addEventListener("click", async () => {
    if (toggle.disabled) return;
    changing = true; error = ""; render();
    try {
      const pref = preferences();
      if (pref.enabled) {
        if (!save(preferenceKey, {...pref,enabled:false})) throw new Error();
        ready = false;
        closeNotices();
        return;
      }
      const permission = granted() ? "granted" : await Notification.requestPermission();
      if (permission !== "granted" || !app.authorized) return;
      const current = preferences();
      if (!current.enabled && !save(preferenceKey, {...current,enabled:true,revision:crypto.randomUUID()})) throw new Error();
      ready = false;
      void tick();
    } catch {
      error = "Desktop notification settings couldn’t be saved.";
    } finally {
      changing = false;
      render();
    }
  });

  agentEnabled.addEventListener("change", () => {
    const profile = window.agentProfiles.current();
    if (!profile || !app.authorized) return;
    const pref = preferences();
    const muted = new Set(pref.muted);
    if (agentEnabled.checked) muted.delete(profile.id); else muted.add(profile.id);
    if (!save(preferenceKey, {...pref,muted:[...muted]})) show("notice", "The browser couldn’t save this notification preference.");
    render();
  });
  window.addEventListener("storage", (event) => {
    if (event.key !== preferenceKey) return;
    if (!preferences().enabled) { ready = false; closeNotices(); }
    render();
    void tick();
  });
  setInterval(() => void tick(), 4000);
  document.addEventListener("visibilitychange", () => void tick());
  window.desktopNotices = {render};
  render();
})();
