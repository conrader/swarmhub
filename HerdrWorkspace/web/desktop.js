(() => {
  const launchButton = document.getElementById("desktop-open");
  if (!launchButton) return;
  const dialog = document.createElement("dialog");
  dialog.id = "desktop-dialog";
  dialog.setAttribute("aria-labelledby", "desktop-title");
  dialog.innerHTML = `<div class="details-header"><h2 id="desktop-title">Agent desktop</h2><button type="button" id="desktop-close">Detach</button></div>
    <p id="desktop-status" role="status"></p>
    <div id="desktop-screen" aria-label="Agent desktop screen"></div>
    <div class="dialog-actions"><button type="button" id="desktop-watch" hidden>Return to watching</button><button type="button" id="desktop-control" disabled>Take over desktop</button></div>`;
  document.body.append(dialog);
  const get = (id) => document.getElementById(id);
  const screen = get("desktop-screen");
  const status = get("desktop-status");
  const watch = get("desktop-watch");
  const control = get("desktop-control");
  let current = null;
  let previous = "";
  let checked = 0;
  let checking = false;
  let stream = null;
  let sequence = 0;
  const teaching = window.desktopTeaching?.create(dialog,screen,detach);

  function desktopKey() {
    const agent = active();
    return app.authorized && app.online && live(agent) ? `${app.core}:${idOf(agent)}` : "";
  }

  function targetMatches(target) {
    return target && app.token === target.token && desktopKey() === `${target.core}:${target.id}`;
  }

  async function render() {
    window.workspaceSkills?.renderDemonstration?.();
    if (dialog.open && current && !targetMatches(current)) detach();
    const key = desktopKey();
    if (key !== previous) {
      previous = key;
      checked = 0;
      launchButton.hidden = true;
    }
    if (!key || checking || (Date.now() - checked < 4000)) return;
    checking = true;
    checked = Date.now();
    try {
      const info = await api(`/api/desktops/${idOf(active())}`);
      if (key === desktopKey()) launchButton.hidden = !info.available;
    } catch {
      if (key === desktopKey()) launchButton.hidden = true;
    } finally { checking = false; }
  }

  function disconnect() {
    ++sequence;
    teaching?.bind();
    stream?.disconnect();
    stream = null;
    screen.replaceChildren();
  }

  function detach() {
    disconnect();
    current = null;
    if (dialog.open) dialog.close();
  }

  async function connect(takeover = false) {
    disconnect();
    if (!current || !dialog.open) return;
    const attempt = sequence;
    const target = current;
    control.disabled = watch.disabled = true;
    status.textContent = takeover ? "Requesting desktop control…" : "Opening a read-only desktop view…";
    const attached = () => attempt === sequence && dialog.open && targetMatches(target);
    try {
      const [{default:RFB}, {path}] = await Promise.all([
        import("/vendor/novnc.js"),
        api(`/api/desktops/${target.id}`, {core:target.core,control:takeover}),
      ]);
      if (!attached()) return;
      if (typeof path !== "string" || !/^\/desktop\/session\/[A-Za-z0-9_-]{43}$/.test(path)) throw new Error("The desktop link was invalid.");
      const url = new URL(path,location.origin);
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const rfb = stream = new RFB(screen,url.href,{shared:true});
      rfb.viewOnly = !takeover;
      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.focusOnClick = takeover;
      rfb.addEventListener("connect", () => {
        if (!attached()) return;
        control.hidden = takeover;
        control.disabled = takeover;
        watch.hidden = !takeover;
        watch.disabled = false;
        status.textContent = takeover ? "You have control. Click the desktop to use its keyboard and pointer."
          : "Watching the desktop. Take over when you need to use the keyboard or pointer.";
        if (takeover) teaching?.bind(screen.querySelector("canvas"),
          () => attached() && stream === rfb && !rfb.viewOnly, () => targetMatches(target));
      });
      rfb.addEventListener("disconnect", () => {
        if (!attached()) return;
        teaching?.bind();
        control.hidden = true;
        watch.hidden = watch.disabled = false;
        watch.textContent = "Reconnect as viewer";
        status.textContent = "The desktop connection ended.";
      });
    } catch (error) {
      if (!attached()) return;
      control.hidden = true;
      watch.hidden = watch.disabled = false;
      watch.textContent = "Reconnect as viewer";
      status.textContent = error.message;
    }
  }

  launchButton.addEventListener("click", () => {
    const agent = active();
    if (!desktopKey() || dialog.open) return;
    current = {core:app.core,id:idOf(agent),token:app.token};
    get("desktop-title").textContent = `${agent.name || "Agent"} desktop`;
    control.hidden = false;
    watch.hidden = true;
    watch.textContent = "Return to watching";
    dialog.showModal();
    void connect();
  });
  control.addEventListener("click", () => void connect(true));
  watch.addEventListener("click", () => {
    watch.textContent = "Return to watching";
    void connect();
  });
  get("desktop-close").addEventListener("click", detach);
  dialog.addEventListener("close", () => {
    if (!dialog.open && current) detach();
  });
  window.swarmDesktop = {render};
})();
