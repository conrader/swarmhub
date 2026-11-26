(() => {
  "use strict";

  const state = { pending: [], history: [], rules: [], commandRules: [], active: null, polling: false, working: false, signature: null };
  const dialog = $("approval-dialog");
  const parkSection = document.createElement("section");
  const parkHeading = document.createElement("h3");
  parkHeading.textContent = "Parked actions";
  const parkList = document.createElement("ul");
  parkList.className = "library-items";
  parkSection.append(parkHeading, parkList);
  $("approval-list-view").append(parkSection);

  const parkDetail = document.createElement("section");
  parkDetail.hidden = true;
  const parkTitle = document.createElement("h3");
  const parkPreview = document.createElement("pre");
  parkPreview.className = "park-preview";
  const parkBack = document.createElement("button");
  parkBack.type = "button";
  parkBack.textContent = "Back to approvals";
  const parkForm = document.createElement("form");
  const parkLabel = document.createElement("label");
  parkLabel.textContent = "Signed park decision JSON";
  const parkInput = document.createElement("textarea");
  parkInput.rows = 5;
  parkInput.required = true;
  parkInput.autocomplete = "off";
  parkInput.spellcheck = false;
  parkLabel.append(parkInput);
  const parkSubmit = document.createElement("button");
  parkSubmit.type = "submit";
  parkSubmit.textContent = "Submit signed decision";
  parkForm.append(parkLabel, parkSubmit);
  const textReview = document.createElement("form");
  textReview.hidden = true;
  const reviewGroup = document.createElement("input");
  const reviewAnswer = document.createElement("input");
  for (const [labelText, input] of [["Group ID", reviewGroup], ["Form answer ID", reviewAnswer]]) {
    const label = document.createElement("label");
    label.textContent = labelText;
    input.inputMode = "numeric";
    input.pattern = "[1-9][0-9]*";
    input.required = true;
    label.append(input);
    textReview.append(label);
  }
  const reviewSubmit = document.createElement("button");
  reviewSubmit.type = "submit";
  reviewSubmit.textContent = "Attach group text review";
  textReview.append(reviewSubmit);
  parkDetail.append(parkTitle, parkPreview, parkForm, textReview, parkBack);
  $("approval-detail").after(parkDetail);
  let parkId = null;
  let parkRequest = 0;

  const status = { approved: "Allow once sent", denied: "Denial sent", terminal: "Returned to the agent" };

  function refreshBadge() {
    const count = $("approval-count");
    count.hidden = !state.pending.length;
    const text = String(state.pending.length);
    if (count.textContent !== text) count.textContent = text;
    if (state.pending.length) count.setAttribute("aria-label", `${text} awaiting review`);
    else count.removeAttribute("aria-label");
  }

  async function load() {
    const token = app.token;
    try {
      const [result, parks] = await Promise.all([
        api("/api/approvals"),
        dialog.open ? api("/api/parks").catch(() => ({ parks: [] })) : { parks: [] },
      ]);
      if (!app.authorized || token !== app.token) return;
      state.parks = parks.parks;
      state.pending = result.pending;
      state.history = result.history;
      state.rules = result.read_rules;
      state.commandRules = result.command_rules || [];
      refreshBadge();
      if (dialog.open) render();
    } catch (error) {
      if (dialog.open) show("approval-notice", error.message);
    } finally {
      state.polling = null;
    }
  }

  function poll() {
    if (!app.authorized) return;
    return state.polling ||= load();
  }

  function item(title, summary) {
    const strong = document.createElement("strong");
    strong.textContent = title;
    const small = document.createElement("small");
    small.textContent = summary;
    return [strong, small];
  }

  function listView() {
    state.active = null;
    parkId = null;
    parkRequest++;
    parkDetail.hidden = true;
    parkInput.value = parkPreview.textContent = "";
    $("approval-input").textContent = $("approval-reviewer").textContent = "";
    $("approval-path").textContent = "";
    state.signature = null;
    $("approval-detail").hidden = true;
    $("approval-command").hidden = true;
    $("approval-remember-options").hidden = true;
    $("approval-list-view").hidden = false;
    render();
  }

  // Render potentially invisible direction/formatting characters visibly in the
  // preview so they cannot disguise parts of the actual command or arguments.
  function visible(value) {
    return value.replace(/[\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/g, (char) =>
      "\\u" + char.charCodeAt(0).toString(16).padStart(4, "0"));
  }

  function details(request) {
    const resources = request.provider === "OpenCode";
    const instruction = resources ? "Review the action and resources before deciding." : "Review the exact arguments before deciding.";
    state.active = { id: request.id, instruction };
    $("approval-list-view").hidden = true;
    $("approval-detail").hidden = false;
    $("approval-action").textContent = `${request.agent} requests ${request.tool}`;
    $("approval-path").textContent = [request.provider, visible(request.cwd)].filter(Boolean).join(" · ");
    $("approval-input").textContent = visible(resources ? JSON.stringify(JSON.parse(request.arguments), null, 2) : request.arguments);
    $("approval-command").hidden = !request.can_remember_command;
    $("approval-remember-options").hidden = !request.can_remember_read;
    show("approval-notice", instruction);
    $("approval-back").focus();
    render();
  }

  function render() {
    if (parkId !== null) return;
    if (state.active) {
      const waiting = state.pending.find(({id}) => id === state.active.id);
      const advice = waiting?.reviewer;
      const reviewer = $("approval-reviewer");
      reviewer.hidden = !advice;
      const reviewText = advice ? `Claude ${advice.model} · ${visible(advice.assessment ?? "Reviewing command…")}` : "";
      if (reviewer.textContent !== reviewText) reviewer.textContent = reviewText;
      for (const button of ["allow", "deny", "terminal", "remember", "command"]) $("approval-" + button).disabled = !waiting || state.working;
      if (!waiting && !state.working && $("approval-notice").textContent === state.active.instruction) {
        $("approval-input").textContent = "";
        $("approval-path").textContent = "";
        show("approval-notice", "This request is no longer waiting. Check the agent’s terminal.");
      }
      return;
    }
    const signature = JSON.stringify([state.pending.map(({id}) => id), state.history, state.rules, state.commandRules, state.parks]);
    if (state.signature === signature) return;
    state.signature = signature;
    $("approval-list").replaceChildren(...state.pending.map((request) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.append(...item(`${request.agent} · ${request.tool}`, `${request.provider} · Waiting until ${displayDate(request.expires_ms)}`));
      button.addEventListener("click", () => details(request));
      row.append(button);
      return row;
    }));
    $("approval-history").replaceChildren(...state.history.map((record) => {
      const row = document.createElement("li");
      const outcome = record.unconfirmed ? "Decision not confirmed · check terminal"
        : record.automatic ? (record.tool === "Bash" ? "Allowed by command rule" : "Allowed by read rule") : status[record.state] || record.state;
      row.append(...item(`${record.agent} · ${record.tool}`,
        `${record.provider} · ${outcome} · ${displayDate(record.resolved_ms ?? record.requested_ms)}`));
      return row;
    }));
    function ruleRow(rule, command) {
      const row = document.createElement("li");
      const detail = command ? `${visible(rule.command)} · ${visible(rule.cwd)} · ${rule.provider}` : `${rule.path} · Until ${displayDate(rule.expires_ms)}`;
      row.append(...item(rule.agent, detail));
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = command ? "Revoke command rule" : "Revoke read rule";
      button.addEventListener("click", async () => {
        if (!app.authorized || button.disabled) return;
        button.disabled = true;
        try {
          await api(`/api/${command ? "project-command-rules" : "approval-rules"}/${rule.id}/revoke`, {});
          show("approval-notice", command ? "Command rule revoked." : "Read rule revoked.");
          await poll();
        } catch (error) { if (dialog.open) show("approval-notice", error.message); }
        finally { button.disabled = false; }
      });
      row.append(button);
      return row;
    }
    $("approval-read-rules").replaceChildren(...state.rules.map(rule => ruleRow(rule, false)));
    $("approval-command-rules").replaceChildren(...state.commandRules.map(rule => ruleRow(rule, true)));
    parkList.replaceChildren(...(state.parks || []).map(({id, state}) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.append(...item(id, state));
      button.addEventListener("click", () => void openPark(id));
      row.append(button);
      return row;
    }));
    parkSection.hidden = !parkList.children.length;
    for (const [id, text] of [["approval-list", "No requests are waiting."], ["approval-history", "No decisions recorded."], ["approval-read-rules","No temporary read rules."], ["approval-command-rules", "No saved command rules."]]) {
      if ($(id).children.length) continue;
      const empty = document.createElement("li");
      empty.textContent = text;
      $(id).append(empty);
    }
  }

  async function decide(choice) {
    const request = state.active;
    if (!request || state.working) return;
    state.working = true;
    render();
    try {
      await api(`/api/approvals/${request.id}`, choice);
      state.pending = state.pending.filter(({id}) => id !== request.id);
      refreshBadge();
      listView();
      show("approval-notice", choice === "terminal" ? "Terminal review requested. Open the agent’s terminal for its prompt."
        : choice === "remember_read" ? "Decision submitted. The rule appears after OpenCode confirms." : "Decision submitted.");
      $("approval-input").textContent = "";
      $("approval-path").textContent = "";
      await poll();
    } catch (error) {
      show("approval-notice", error.message);
      await poll();
    } finally {
      state.working = false;
      render();
    }
  }

  async function open(id) {
    show("approval-notice", "");
    dialog.showModal();
    listView();
    await poll();
    if (id === undefined || !dialog.open) return;
    const request = state.pending.find((row) => row.id === id);
    if (request) details(request);
    else show("approval-notice", "This request is no longer waiting for a decision.");
  }
  async function showPark(id) {
    const request = ++parkRequest;
    const token = app.token;
    parkId = id;
    state.active = null;
    $("approval-list-view").hidden = $("approval-detail").hidden = true;
    parkDetail.hidden = false;
    parkForm.hidden = textReview.hidden = true;
    reviewGroup.value = reviewAnswer.value = "";
    parkTitle.textContent = id;
    parkPreview.textContent = "";
    const result = await api("/api/parks/" + encodeURIComponent(id));
    if (!dialog.open || !app.authorized || app.token !== token || request !== parkRequest) return;
    const { detail, pin, classification, outbound } = result;
    const parkState = detail.view.status ?? detail.view.receipt?.[0];
    parkTitle.textContent = [id, parkState].filter(Boolean).join(" · ");
    parkPreview.textContent = visible(JSON.stringify({
      pin, outbound: outbound ?? undefined, manifest: detail.manifest, classification,
      decision: detail.decision, receipt: detail.view.receipt?.[1],
      supersedes: detail.supersedes, superseded_by: detail.superseded_by,
    }, null, 2));
    parkForm.hidden = !["pending", "held", "failed"].includes(parkState);
    parkLabel.firstChild.textContent = outbound
      ? "Signed outbound decision JSON (authorize_outbound)" : "Signed park decision JSON";
    textReview.hidden = !outbound || parkState !== "pending" || Boolean(outbound.text_review);
  }

  async function openPark(id) {
    if (!app.authorized) return;
    if (!dialog.open) dialog.showModal();
    show("approval-notice", "");
    parkInput.value = "";
    try { await showPark(id); }
    catch (error) { if (dialog.open && parkId === id) show("approval-notice", error.message); }
    parkBack.focus();
  }

  parkBack.addEventListener("click", () => { show("approval-notice", ""); listView(); void poll(); });

  textReview.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!app.authorized || reviewSubmit.disabled || parkId === null) return;
    const id = parkId;
    reviewSubmit.disabled = true;
    try {
      const group = Number(reviewGroup.value);
      const answer = Number(reviewAnswer.value);
      if (!Number.isSafeInteger(group) || !Number.isSafeInteger(answer)) throw new Error("Enter valid group and answer IDs.");
      await api(`/api/groups/${group}/outbound-text-review`, {park: id, answer});
      if (!dialog.open || parkId !== id) return;
      await showPark(id);
      show("approval-notice", "Text review attached.");
    } catch (error) {
      if (dialog.open && parkId === id) show("approval-notice", error.message);
    } finally { reviewSubmit.disabled = false; }
  });

  parkForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!app.authorized || parkSubmit.disabled || parkId === null) return;
    const id = parkId;
    parkSubmit.disabled = true;
    try {
      let input;
      try { input = JSON.parse(parkInput.value); }
      catch { throw new Error("Enter a signed decision as JSON."); }
      const signed = input.signed ?? input;
      const pin = signed.envelope?.target?.park;
      if (pin?.id !== id) throw new Error("The signature must name this park.");
      const result = await api("/api/parks/decide", {
        park: { id, manifest_digest: pin.manifest_digest },
        purpose: signed.envelope.purpose,
        evidence: { signed },
        replacement: input.replacement,
      });
      if (!dialog.open || parkId !== id) return;
      if (result.view === "busy") {
        show("approval-notice", "The workspace is busy. Retry the decision.");
        return;
      }
      parkInput.value = "";
      await showPark(id);
      if (result.result === "outbound_approved") {
        show("approval-notice", "Signed decision recorded. Sending is disabled.");
      } else if (result.reason === "outbound_disabled") {
        show("approval-notice", "Sending is disabled.");
      } else {
        show("approval-notice", result.result === "held" ? "The park was held: " + result.reason : "Decision recorded.");
      }
    } catch (error) {
      if (dialog.open && parkId === id) show("approval-notice", error.message);
    } finally { parkSubmit.disabled = false; }
  });

  function lockIfNeeded() {
    if (app.authorized) return;
    if (dialog.open) dialog.close();
    state.pending = state.history = state.rules = state.commandRules = state.parks = [];
    parkList.replaceChildren();
    state.active = null;
    refreshBadge();
    $("approval-input").textContent = $("approval-reviewer").textContent = $("approval-path").textContent = $("approval-action").textContent = "";
    for (const id of ["approval-list", "approval-history", "approval-read-rules", "approval-command-rules"]) $(id).replaceChildren();
  }
  window.approvalInbox = { open, openPark, lockIfNeeded };
  $("approvals-open").addEventListener("click", () => void open());
  $("approval-close").addEventListener("click", () => { if (!state.working) dialog.close(); });
  $("approval-back").addEventListener("click", () => { show("approval-notice", ""); listView(); });
  $("approval-allow").addEventListener("click", () => decide("approve"));
  $("approval-command").addEventListener("click", () => decide("remember_command"));
  $("approval-remember").addEventListener("click", () => decide("remember_read"));
  $("approval-deny").addEventListener("click", () => decide("deny"));
  $("approval-terminal").addEventListener("click", () => decide("terminal"));
  dialog.addEventListener("cancel", (event) => { if (state.working) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    parkId = null;
    parkRequest++;
    parkInput.value = parkPreview.textContent = "";
    state.active = null;
    $("approval-input").textContent = $("approval-reviewer").textContent = "";
    $("approval-path").textContent = "";
  });
  setInterval(poll, 1800);
})();
