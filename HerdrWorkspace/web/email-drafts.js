(() => {
  "use strict";

  const dialog = document.createElement("dialog");
  dialog.id = "email-draft-dialog";
  dialog.setAttribute("aria-labelledby", "email-draft-heading");
  dialog.innerHTML = `
    <div class="details-header"><h2 id="email-draft-heading">Review email draft</h2><button type="button" id="email-draft-close" class="icon" aria-label="Close email draft">×</button></div>
    <p id="email-draft-status" role="status" hidden></p>
    <form id="email-draft-form" hidden>
      <label for="email-draft-sender">Sending email address</label>
      <input id="email-draft-sender" inputmode="email" maxlength="254" autocomplete="off">
      <label for="email-draft-to">To</label>
      <input id="email-draft-to" inputmode="email" maxlength="2540" autocomplete="off" aria-describedby="email-draft-addresses">
      <p id="email-draft-addresses" class="subtle">Separate email addresses with commas.</p>
      <label for="email-draft-cc">Cc</label>
      <input id="email-draft-cc" inputmode="email" maxlength="2540" autocomplete="off">
      <label for="email-draft-bcc">Bcc</label>
      <input id="email-draft-bcc" inputmode="email" maxlength="2540" autocomplete="off">
      <label for="email-draft-subject">Subject</label>
      <input id="email-draft-subject" maxlength="240" autocomplete="off">
      <label for="email-draft-reply">In-Reply-To message ID</label>
      <input id="email-draft-reply" maxlength="256" autocomplete="off">
      <label for="email-draft-thread">Thread ID</label>
      <input id="email-draft-thread" maxlength="128" autocomplete="off">
      <label for="email-draft-body">Message</label>
      <textarea id="email-draft-body" rows="8" maxlength="24576" required spellcheck="true"></textarea>
      <p class="subtle">Stage a revision for signed approval or download a draft for manual delivery. Sending is disabled.</p>
      <p id="email-draft-receipt" role="status" hidden></p>
      <ul id="email-draft-inflight" hidden></ul>
      <p id="email-draft-error" class="error" role="alert" hidden></p>
      <button type="button" id="email-draft-dismiss">Dismiss draft</button>
      <div class="dialog-actions"><button type="button" id="email-draft-cancel">Close</button><button type="button" id="email-draft-preview" hidden>Open approval preview</button><button type="button" id="email-draft-stage">Stage for approval</button><button type="submit" id="email-draft-download" class="primary">Download .eml draft</button></div>
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
  const sender = $("email-draft-sender");
  const cc = $("email-draft-cc");
  const bcc = $("email-draft-bcc");
  const reply = $("email-draft-reply");
  const thread = $("email-draft-thread");
  const fields = [sender, to, cc, bcc, subject, reply, thread, body];
  const stageButton = $("email-draft-stage");

  function emailFields() {
    const addresses = (input) => input.value.trim() ? input.value.split(",").map((value) => value.trim()) : [];
    return {channel: "email", sender: sender.value.trim(), to: addresses(to), cc: addresses(cc),
      bcc: addresses(bcc), subject: subject.value, in_reply_to: reply.value.trim() || null,
      thread_id: thread.value.trim() || null, body: body.value};
  }

  function receiptLabel(receipt) {
    switch (receipt?.status) {
      case "accepted": return `Provider accepted · Receipt ${receipt.provider_id}`;
      case "submitting": return "Provider submission pending";
      case "reconciliation": return "Delivery uncertain · Awaiting Sent-folder confirmation";
      case "not_submitted": return "Provider submission did not occur";
      default: return "";
    }
  }

  function showStage(staged) {
    const email = staged.payload;
    sender.value = email.sender;
    to.value = email.to.join(", ");
    cc.value = email.cc.join(", ");
    bcc.value = email.bcc.join(", ");
    subject.value = email.subject;
    reply.value = email.in_reply_to ?? "";
    thread.value = email.thread_id ?? "";
    body.value = email.body;
    $("email-draft-dismiss").hidden = true;
    $("email-draft-preview").hidden = false;
    stageButton.textContent = "Stage updated revision";
    $("email-draft-download").textContent = "Download staged .eml";
    const flight = $("email-draft-inflight");
    flight.replaceChildren(...staged.in_flight.map((entry) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = `Open revision ${entry.version} · ${receiptLabel(entry.receipt) || entry.state}`;
      button.addEventListener("click", () => openPreview(entry.park));
      item.append(button);
      return item;
    }));
    flight.hidden = !flight.children.length;
    const approval = staged.approval_revoked ? "Approval revoked"
      : staged.approval ? "Signed decision on file" : "Awaiting signed decision";
    show("email-draft-status", `Revision ${staged.version} · ${approval} · ${staged.state}`);
    show("email-draft-receipt", receiptLabel(staged.receipt));
  }

  function openPreview(id) {
    dialog.close();
    void window.approvalInbox.openPark(id);
  }

  function clear() {
    current = null;
    show("email-draft-receipt", "");
    for (const field of fields) field.value = "";
    $("email-draft-inflight").replaceChildren();
    $("email-draft-inflight").hidden = true;
    $("email-draft-dismiss").hidden = false;
    $("email-draft-preview").hidden = true;
    stageButton.textContent = "Stage for approval";
    $("email-draft-download").textContent = "Download .eml draft";
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
      current = {path, revision: result.revision, staged: result.staged, visible};
      $("email-draft-heading").textContent = result.state === "reviewed" ? "Email draft" : "Review email draft";
      to.value = result.draft.to;
      subject.value = result.draft.subject;
      body.value = result.draft.body;
      show("email-draft-status", "");
      if (current.staged) showStage(current.staged);
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
    for (const field of fields) field.disabled = active;
    for (const id of ["email-draft-close", "email-draft-cancel", "email-draft-dismiss",
      "email-draft-download", "email-draft-stage", "email-draft-preview"]) $(id).disabled = active;
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

  $("email-draft-preview").addEventListener("click", () => {
    if (!saving && current?.visible() && current.staged) openPreview(current.staged.park.id);
  });

  stageButton.addEventListener("click", async () => {
    const target = current;
    if (!target?.visible() || saving) return;
    busy(true);
    show("email-draft-error", "");
    try {
      const {channel, ...email} = emailFields();
      const staged = await api(target.path + "/stage", {
        revision: target.revision, version: target.staged?.version ?? 0, email,
      });
      if (!target.visible()) return;
      target.staged = staged;
      showStage(staged);
    } catch (error) {
      if (target.visible()) show("email-draft-error", error.message);
    } finally {
      busy(false);
      if (target.visible() && target.staged) $("email-draft-preview").focus();
    }
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
    const staged = target.staged;
    if (!staged && [sender, cc, bcc, reply, thread].some((field) => field.value.trim())) {
      show("email-draft-error", "Stage the complete email before downloading these fields.");
      return;
    }
    if (staged && Object.entries(emailFields()).some(([key, value]) =>
      JSON.stringify(value) !== JSON.stringify(staged.payload[key]))) {
      show("email-draft-error", "Stage your edits before downloading this revision.");
      return;
    }
    busy(true);
    show("email-draft-status", "Preparing the draft file…");
    show("email-draft-error", "");
    try {
      const response = await fetch(target.path + (staged ? "/staged-download" : "/download"), {
        method: "POST",
        headers: {"Authorization": "Bearer " + app.token, "Content-Type": "application/json"},
        body: JSON.stringify(staged ? {revision: staged.version} : {revision: target.revision, draft}),
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
      if (!staged) {
        mark(target.path, "reviewed");
        $("email-draft-heading").textContent = "Email draft";
      }
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
