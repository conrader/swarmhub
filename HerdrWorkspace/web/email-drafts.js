(() => {
  "use strict";

  const dialog = document.createElement("dialog");
  dialog.id = "email-draft-dialog";
  dialog.setAttribute("aria-labelledby", "email-draft-heading");
  dialog.innerHTML = `
    <div class="details-header"><h2 id="email-draft-heading">Review email draft</h2><button type="button" id="email-draft-close" class="icon" aria-label="Close email draft">×</button></div>
    <p id="email-draft-status" role="status" hidden></p>
    <form id="email-draft-form" hidden>
      <label for="email-draft-to">To</label>
      <input id="email-draft-to" inputmode="email" maxlength="1024" autocomplete="off" aria-describedby="email-draft-addresses">
      <p id="email-draft-addresses" class="subtle">Separate email addresses with commas, or leave this blank.</p>
      <label for="email-draft-subject">Subject</label>
      <input id="email-draft-subject" maxlength="240" autocomplete="off">
      <label for="email-draft-body">Message</label>
      <textarea id="email-draft-body" rows="8" maxlength="24576" required spellcheck="true"></textarea>
      <p class="subtle">Download saves your edits and creates a plain-text draft file. SwarmHub doesn’t send email.</p>
      <p id="email-draft-error" class="error" role="alert" hidden></p>
      <button type="button" id="email-draft-dismiss">Dismiss draft</button>
      <div class="dialog-actions"><button type="button" id="email-draft-cancel">Close</button><button type="submit" id="email-draft-download" class="primary">Download .eml draft</button></div>
    </form>`;
  document.body.append(dialog);

  let current = null;
  let sequence = 0;
  let saving = false;
  const form = $("email-draft-form");
  const to = $("email-draft-to");
  const subject = $("email-draft-subject");
  const body = $("email-draft-body");
  const encoder = new TextEncoder();

  function clear() {
    current = null;
    to.value = subject.value = body.value = "";
    form.hidden = true;
  }

  function label(button, state) {
    button.disabled = state === "dismissed";
    button.textContent = state === "dismissed" ? "Email draft dismissed"
      : state === "reviewed" ? "Open email draft" : "Review email draft";
  }

  function mark(path, status) {
    const prefix = app.selected && app.historyCore
      ? "/api/history/" + encodeURIComponent(app.historyCore) + "/" + app.selected + "/email-drafts/" : null;
    if (prefix && path.startsWith(prefix)) {
      const entry = app.history.entries.find((item) => item.id === Number(path.slice(prefix.length)));
      if (entry) entry.email_draft = status;
    }
    for (const button of document.querySelectorAll("[data-email-draft]")) {
      if (button.dataset.emailDraft === path) label(button, status);
    }
  }

  async function open(path) {
    if (dialog.open || !app.authorized) return;
    const requested = ++sequence;
    const token = app.token;
    const visible = () => dialog.open && sequence === requested && app.authorized && app.token === token;
    clear();
    $("email-draft-heading").textContent = "Review email draft";
    show("email-draft-status", "Loading email draft…");
    show("email-draft-error", "");
    dialog.showModal();
    try {
      const result = await api(path);
      if (!visible()) return;
      if (!result.draft) {
        show("email-draft-status", "This email draft was dismissed.");
        mark(path, "dismissed");
        return;
      }
      current = {path, revision: result.revision, visible};
      $("email-draft-heading").textContent = result.state === "reviewed" ? "Email draft" : "Review email draft";
      to.value = result.draft.to;
      subject.value = result.draft.subject;
      body.value = result.draft.body;
      show("email-draft-status", "");
      form.hidden = false;
      to.focus();
    } catch (error) {
      if (visible()) show("email-draft-status", error.message);
    }
  }

  function lockIfNeeded() {
    if (app.authorized || !dialog.open) return;
    ++sequence;
    clear();
    dialog.close();
  }

  function busy(active) {
    saving = active;
    for (const id of ["email-draft-to", "email-draft-subject", "email-draft-body",
      "email-draft-close", "email-draft-cancel", "email-draft-dismiss", "email-draft-download"]) $(id).disabled = active;
  }

  function close() { if (!saving) dialog.close(); }
  $("email-draft-close").addEventListener("click", close);
  $("email-draft-cancel").addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open) return;
    ++sequence;
    clear();
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const target = current;
    if (!target?.visible() || saving) return;
    const draft = {to: to.value, subject: subject.value, body: body.value};
    if (!draft.body.trim() || encoder.encode(draft.body).length > 24576) {
      show("email-draft-error", "Enter an email message up to 24 KiB.");
      body.focus();
      return;
    }
    busy(true);
    show("email-draft-status", "Preparing the draft file…");
    show("email-draft-error", "");
    try {
      const response = await fetch(target.path + "/download", {
        method: "POST",
        headers: {"Authorization": "Bearer " + app.token, "Content-Type": "application/json"},
        body: JSON.stringify({revision: target.revision, draft}),
      });
      if (!response.ok) {
        const error = await response.json().catch(() => null);
        throw new Error(error?.error || "Couldn’t prepare the email draft.");
      }
      const data = await response.blob();
      if (!target.visible()) return;
      target.revision = Number(response.headers.get("x-swarmhub-email-revision")) || target.revision;
      const link = document.createElement("a");
      link.href = URL.createObjectURL(data);
      link.download = "swarmhub-email-draft.eml";
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
      mark(target.path, "reviewed");
      $("email-draft-heading").textContent = "Email draft";
      show("email-draft-status", "Draft downloaded. No email was sent.");
    } catch (error) {
      if (!target.visible()) return;
      show("email-draft-status", "");
      show("email-draft-error", error.message);
    } finally {
      busy(false);
      if (target.visible()) $("email-draft-download").focus();
    }
  });

  $("email-draft-dismiss").addEventListener("click", async () => {
    const target = current;
    if (!target?.visible() || saving) return;
    busy(true);
    show("email-draft-error", "");
    try {
      await api(target.path + "/dismiss", {revision: target.revision});
      if (!target.visible()) return;
      mark(target.path, "dismissed");
      clear();
      show("email-draft-status", "Email draft dismissed.");
    } catch (error) {
      if (target.visible()) show("email-draft-error", error.message);
    } finally {
      busy(false);
      if (target.visible() && form.hidden) $("email-draft-close").focus();
    }
  });

  window.workspaceEmailDrafts = { label, lockIfNeeded, open };
})();
