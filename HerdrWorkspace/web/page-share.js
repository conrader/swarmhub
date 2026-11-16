(() => {
  "use strict";
  const dialog = $("page-share-dialog");
  const mode = $("page-share-mode");
  const href = $("page-share-url");
  const create = $("page-share-create");
  const revoke = $("page-share-revoke");
  const close = $("page-share-close");
  let context = null;
  let link = null;
  let ready = false;
  let busy = false;

  function active(ticket) { return app.authorized && app.token === ticket.access && dialog.open && context === ticket; }

  function showState() {
    $("page-share-options").hidden = !ready || Boolean(link);
    $("page-share-active").hidden = !link;
    $("page-share-active").textContent = link
      ? `${link.follow_latest ? "Follows updates" : `Fixed at revision ${link.revision}`} · Expires ${displayDate(link.expires_ms)}` : "";
    $("page-share-result").hidden = !href.value;
    $("page-share-copy").disabled = busy || !href.value;
    revoke.hidden = !link;
    create.disabled = revoke.disabled = mode.disabled = busy || !ready;
    close.disabled = busy;
  }

  function prompt() {
    $("page-share-scope").textContent = mode.value === "live"
      ? "People with this link can see future edits, including changes made by an agent."
      : `People with this link can only see revision ${context?.revision}.`;
  }

  async function open(page) {
    if (!app.authorized || dialog.open || !page) return;
    const ticket = { access:app.token, revision:page.revision, url:`/api/pages/${page.id}/share` };
    context = ticket;
    ready = busy = false;
    link = null;
    href.value = "";
    mode.value = "fixed";
    prompt();
    show("page-share-status", "Checking for a viewer link…");
    showState();
    dialog.showModal();
    try {
      const result = await api(ticket.url);
      if (!active(ticket)) return;
      link = result.link;
      ready = true;
      show("page-share-status", link ? "The address is shown only when the link is created. To get a new address, revoke this link first." : "");
    } catch (error) {
      if (active(ticket)) show("page-share-status", error.message);
    } finally {
      if (active(ticket)) showState();
    }
  }

  async function change(action) {
    const ticket = context;
    if (!ticket || !active(ticket) || !ready || busy || (action === "create" ? Boolean(link) : !link)) return;
    busy = true;
    showState();
    show("page-share-status", action === "create" ? "Creating viewer link…" : "Revoking viewer link…");
    try {
      const result = await api(ticket.url, action === "create"
        ? {action, revision:ticket.revision, follow_latest:mode.value === "live"}
        : {action, id:link.id});
      if (!active(ticket)) return;
      link = result.link;
      if (action === "create") {
        const url = new URL("/view/page", location.origin);
        url.hash = result.token;
        href.value = url.href;
        show("page-share-status", "Link created. Copy it before closing this window.");
      } else {
        href.value = "";
        show("page-share-status", "Viewer link revoked.");
      }
    } catch (error) {
      if (active(ticket)) {
        ready = false;
        href.value = "";
        show("page-share-status", error.message + " Reopen sharing to check the link before trying again.");
      }
    } finally {
      if (active(ticket)) {
        busy = false;
        showState();
        if (href.value) $("page-share-copy").focus();
      }
    }
  }

  function clear() {
    context = link = null;
    href.value = "";
    ready = busy = false;
    show("page-share-status", "");
    showState();
  }
  function closeForPage() {
    if (dialog.open) { clear(); dialog.close(); }
  }

  close.addEventListener("click", () => { if (!busy) closeForPage(); });
  dialog.addEventListener("cancel", (event) => { if (busy) event.preventDefault(); else clear(); });
  mode.addEventListener("change", prompt);
  create.addEventListener("click", () => void change("create"));
  revoke.addEventListener("click", () => void change("revoke"));
  $("page-share-copy").addEventListener("click", async () => {
    const ticket = context;
    if (!ticket || !href.value) return;
    try {
      await navigator.clipboard.writeText(href.value);
      if (active(ticket)) show("page-share-status", "Viewer link copied.");
    } catch {
      if (!active(ticket)) return;
      href.focus();
      href.select();
      show("page-share-status", "Copy the address from the selected field.");
    }
  });
  window.pageShare = { open, close: closeForPage };
})();
