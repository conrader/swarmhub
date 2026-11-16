(() => {
  "use strict";

  const dialog = $("terminal-dialog");
  const host = $("terminal-host");
  const encoder = new TextEncoder();
  let session = null;

  function sendControl(state, control) {
    if (!state.ready || state.socket.readyState !== WebSocket.OPEN) return;
    state.socket.send(JSON.stringify(control));
  }

  function sendBytes(state, bytes) {
    if (!state.ready || state.socket.readyState !== WebSocket.OPEN) return;
    if (state.socket.bufferedAmount + bytes.length > 512 * 1024) {
      $("terminal-status").textContent = "Input is backed up. Wait a moment before sending more.";
      return;
    }
    for (let i = 0; i < bytes.length; i += 16 * 1024) {
      state.socket.send(bytes.subarray(i, i + 16 * 1024));
    }
  }

  function fit(state) {
    const geometry = state.fit.proposeDimensions();
    if (!geometry) return;
    state.terminal.resize(
      Math.min(300, Math.max(2, geometry.cols)),
      Math.min(120, Math.max(1, geometry.rows))
    );
  }

  function detach() {
    const state = session;
    session = null;
    if (!state) return;
    state.ready = false;
    state.observer.disconnect();
    if (state.socket.readyState < WebSocket.CLOSING) state.socket.close();
    state.terminal.dispose();
    host.replaceChildren();
  }

  function open() {
    const agent = active();
    if (!app.online || !live(agent) || !app.terminalAttach || session) return;
    if (!window.Terminal || !window.FitAddon?.FitAddon) {
      show("notice", "The terminal viewer could not load. Reload the workspace and try again.");
      return;
    }
    $("terminal-heading").textContent = `${title(agent)} · Terminal`;
    $("terminal-status").textContent = "Connecting to Herdr…";
    dialog.showModal();
    const terminal = new window.Terminal({
      scrollback: 1500, fontSize: 13, fontFamily: "ui-monospace, monospace", cursorBlink: false,
      screenReaderMode: true, theme: { background: "#111318", foreground: "#e2e4ef" },
      linkHandler: { activate() {}, allowNonHttpProtocols: false },
      disableStdin: true
    });
    const addon = new window.FitAddon.FitAddon();
    terminal.loadAddon(addon);
    terminal.open(host);
    terminal.textarea?.setAttribute("aria-label", "Control the agent terminal");
    const origin = location.origin.replace(/^http/, "ws");
    const socket = new WebSocket(`${origin}/attach/${idOf(agent)}`);
    socket.binaryType = "arraybuffer";
    const observer = new ResizeObserver(() => {
      if (session === state && dialog.open) fit(state);
    });
    const state = { terminal, fit: addon, socket, observer, ready: false, ended: false };
    session = state;
    fit(state);
    observer.observe(host);

    socket.addEventListener("open", () => {
      if (session !== state) return;
      socket.send(JSON.stringify({ token: app.token, cols: terminal.cols, rows: terminal.rows }));
    });
    socket.addEventListener("message", ({data}) => {
      if (session !== state) return;
      if (typeof data === "string") {
        let message;
        try { message = JSON.parse(data); }
        catch { socket.close(); return; }
        if (message.type === "ready") {
          state.ready = true;
          terminal.options.disableStdin = false;
          $("terminal-status").textContent = "Attached · input goes directly to the agent";
          sendControl(state, { type: "resize", cols: terminal.cols, rows: terminal.rows });
          terminal.focus();
        } else {
          state.ended = true;
          state.ready = false;
          terminal.options.disableStdin = true;
          $("terminal-status").textContent = message.message;
        }
        return;
      }
      const bytes = new Uint8Array(data);
      terminal.write(bytes, () => {
        if (session === state) sendControl(state, { type: "credit", bytes: bytes.length });
      });
    });
    socket.addEventListener("close", () => {
      if (session !== state) return;
      state.ready = false;
      terminal.options.disableStdin = true;
      if (!state.ended) $("terminal-status").textContent = "Terminal detached. Reopen it to reconnect.";
    });
    socket.addEventListener("error", () => {
      if (session !== state) return;
      state.ended = true;
      $("terminal-status").textContent = "Could not connect to the terminal.";
    });
    terminal.onData((input) => sendBytes(state, encoder.encode(input)));
    terminal.onBinary((input) => sendBytes(state, Uint8Array.from(input, (byte) => byte.charCodeAt(0))));
    terminal.onResize(({cols, rows}) => sendControl(state, { type: "resize", cols, rows }));
    host.addEventListener("focusin", () => sendControl(state, { type: "focus", focused: true }), { signal: listeners.signal });
    host.addEventListener("focusout", (event) => {
      if (!host.contains(event.relatedTarget)) sendControl(state, { type: "focus", focused: false });
    }, { signal: listeners.signal });
  }

  let listeners = new AbortController();
  $("takeover").addEventListener("click", open);
  $("terminal-close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => {
    listeners.abort();
    listeners = new AbortController();
    detach();
    if (!$("takeover").hidden) $("takeover").focus();
    void refresh();
  });
  dialog.addEventListener("cancel", (event) => {
    if (host.contains(document.activeElement)) event.preventDefault();
  });
})();
