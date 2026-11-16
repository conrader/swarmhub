(() => {
  "use strict";
  const title = document.getElementById("shared-title");
  const status = document.getElementById("shared-status");
  const retry = document.getElementById("shared-retry");
  const content = document.getElementById("shared-content");
  const tables = new Map();
  let controller;
  let revision = null;
  let timer;
  let unavailable = false;

  function blank(message, canRetry = false) {
    revision = null;
    title.textContent = "Shared Page";
    document.title = "SwarmHub · Shared Page";
    status.textContent = message;
    retry.hidden = !canRetry;
    content.hidden = true;
    content.replaceChildren();
  }

  function showPage(page) {
    const focused = content.contains(document.activeElement) ? document.activeElement.id : "";
    revision = page.revision;
    title.textContent = page.title;
    // Keep content and its title out of shared browser history.
    status.textContent = `Revision ${revision} · Read-only`;
    retry.hidden = true;
    content.innerHTML = page.html; // Rendered by the workspace's restricted Markdown renderer.
    for (const link of content.querySelectorAll("a")) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }
    for (const box of content.querySelectorAll('input[type="checkbox"]')) box.disabled = true;
    window.renderPageTables(content, tables);
    window.renderPageCharts(content);
    content.hidden = false;
    if (focused) document.getElementById(focused)?.focus({preventScroll:true});
  }

  function stop() {
    controller?.abort();
    controller = undefined;
    clearTimeout(timer);
  }

  async function read() {
    if (controller || document.hidden || unavailable) return;
    clearTimeout(timer);
    const token = location.hash.slice(1);
    if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
      blank("This viewer link is missing or invalid.");
      return;
    }
    const request = new AbortController();
    controller = request;
    // A stalled revalidation cannot leave a previous revision visible indefinitely.
    const deadline = setTimeout(() => request.abort(), 8000);
    const url = "/view/page/content" + (revision == null ? "" : `?after=${revision}`);
    try {
      const response = await fetch(url, {headers:{Authorization:`PageLink ${token}`},
        credentials:"omit", cache:"no-store", redirect:"error", signal:request.signal});
      if (controller !== request) return;
      if (response.status === 204) return;
      if (response.status === 404) {
        unavailable = true;
        tables.clear();
        blank("This viewer link has expired or is no longer available.");
        return;
      }
      if (!response.ok) throw new Error("Not available");
      const page = await response.json();
      if (controller === request) showPage(page);
    } catch {
      if (controller === request) blank("Can’t reach this Page. Check your connection and try again.", true);
    } finally {
      clearTimeout(deadline);
      if (controller === request) {
        controller = undefined;
        if (!unavailable) timer = setTimeout(read, 4000);
      }
    }
  }

  window.addEventListener("hashchange", () => {
    stop();
    tables.clear();
    unavailable = false;
    blank("Opening Page…");
    void read();
  });
  window.addEventListener("pagehide", () => { stop(); blank("Opening Page…"); });
  window.addEventListener("pageshow", () => {
    unavailable = false;
    void read();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      stop();
      if (!unavailable) blank("Checking viewer link…");
    }
    else void read();
  });
  retry.addEventListener("click", () => void read());
})();
