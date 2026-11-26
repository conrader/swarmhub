"use strict";

window.openTerminalPreview = (address, created, token, expectedCore) => {
  const viewport = document.getElementById("viewport");
  const grid = document.getElementById("grid");
  const status = document.getElementById("status");
  const term = new window.Terminal({
    cols: 80, rows: 24, fontFamily: "ui-monospace, monospace", fontSize: 14,
    scrollback: 0, disableStdin: true, cursorBlink: false, screenReaderMode: true,
    theme: { background: "#111318", foreground: "#e2e4ef" },
    linkHandler: { activate() {}, allowNonHttpProtocols: false }
  });
  term.open(grid);
  const fit = () => {
    const screen = grid.querySelector(".xterm-screen");
    if (!screen || !screen.offsetWidth || !screen.offsetHeight) return;
    const scale = Math.min(viewport.clientWidth / screen.offsetWidth, viewport.clientHeight / screen.offsetHeight);
    grid.style.transform = "scale(" + scale + ")";
  };
  const size = (cols, rows) => {
    if (Number.isInteger(cols) && Number.isInteger(rows) && cols > 0 && rows > 0 && cols <= 2000 && rows <= 1000) {
      if (term.cols !== cols || term.rows !== rows) term.resize(cols, rows);
      fit();
    }
  };
  const observer = new ResizeObserver(fit);
  observer.observe(viewport);
  observer.observe(grid.querySelector(".xterm-screen"));
  const path = encodeURIComponent(address) + "/" + created;
  const socket = new WebSocket(location.origin.replace(/^http/, "ws") + "/attach/" + path);
  socket.binaryType = "arraybuffer";
  let watching = false;
  let timer;
  let announcedEnd = false;
  async function refreshGeometry() {
    try {
      const result = await fetch("/api/agents/" + path + "/geometry", {headers: {Authorization: "Bearer " + token}});
      if (result.ok && watching) {
        const geometry = await result.json();
        size(geometry.cols, geometry.rows);
      }
    } catch {}
    if (watching) timer = setTimeout(refreshGeometry, 3000);
  }
  socket.onopen = () => socket.send(JSON.stringify({token, cols: 80, rows: 24, observe: true, expected_core: expectedCore}));
  socket.onmessage = ({data}) => {
    if (typeof data === "string") {
      const msg = JSON.parse(data);
      if (msg.type === "ready" && msg.observe === true) {
        size(msg.cols, msg.rows);
        status.textContent = "";
        watching = true;
        timer = setTimeout(refreshGeometry, 3000);
      } else {
        status.textContent = msg.message || "Preview unavailable.";
        announcedEnd = true;
      }
    } else if (watching) {
      const bytes = new Uint8Array(data);
      term.write(bytes, () => {
        if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({type: "credit", bytes: bytes.length}));
      });
    }
  };
  socket.onclose = () => {
    watching = false;
    clearTimeout(timer);
    if (!announcedEnd) status.textContent = "Terminal disconnected.";
  };
  window.addEventListener("pagehide", () => {
    watching = false;
    clearTimeout(timer);
    observer.disconnect();
    socket.close();
    term.dispose();
  }, { once: true });
};
