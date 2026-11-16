"use strict";

(() => {
  const launch = document.getElementById("opencode-model-open");
  if (!launch) return;
  const dialog = document.createElement("dialog");
  dialog.id = "opencode-model-dialog";
  dialog.setAttribute("aria-labelledby", "opencode-model-heading");
  dialog.innerHTML = `
    <form id="opencode-model-form">
      <div class="details-header"><h2 id="opencode-model-heading">OpenCode session model</h2>
        <button id="opencode-model-close" class="icon" type="button" aria-label="Close model settings">×</button>
      </div>
      <p class="subtle">Choose a model for later tasks sent from SwarmHub. This does not change running work. Mini’s display may differ.</p>
      <dl><dt>Current selection</dt><dd id="opencode-model-current">—</dd>
        <dt>OpenCode default</dt><dd id="opencode-model-default">—</dd></dl>
      <label for="opencode-model-mode">Change to</label>
      <select id="opencode-model-mode">
        <option value="select">Choose an exact model</option>
        <option value="reset">Restore the configured default</option>
      </select>
      <div id="opencode-model-id-field">
        <label for="opencode-model-id">Provider/model ID</label>
        <input id="opencode-model-id" maxlength="160" list="opencode-session-model-options" autocomplete="off" spellcheck="false">
        <datalist id="opencode-session-model-options"></datalist>
        <button id="opencode-model-load" type="button" hidden>Load model IDs</button>
      </div>
      <p id="opencode-model-review" class="subtle" aria-live="polite"></p>
      <p id="opencode-model-status" role="status" tabindex="-1"></p>
      <div class="dialog-actions">
        <button id="opencode-model-refresh" type="button">Read current selection</button>
        <button id="opencode-model-apply" type="submit" class="primary">Apply model</button>
      </div>
    </form>`;
  document.body.append(dialog);
  const element = (name) => document.getElementById("opencode-model-" + name);
  const mode = element("mode"), id = element("id"), options = document.getElementById("opencode-session-model-options");
  let target, ticket, state, busy = false, listing = false;

  const pendingWork = () => ["working", "blocked"].includes(target?.status);
  const selectedID = () => mode.value === "reset" ? state?.default_model : id.value.trim();
  const valid = (value) => typeof value === "string" && value.length <= 160 &&
    /^[\da-z][\da-z_.-]*\/[\da-z][\da-z_.:/@+#\[\]-]*$/i.test(value);
  const sameTicket = (request) => dialog.open && ticket === request;

  function draw() {
    element("current").textContent = state ? (state.current || "OpenCode chooses") : "—";
    element("default").textContent = state?.default_model || (state ? "Not reported" : "—");
    mode.disabled = busy || !state;
    mode.options[1].disabled = !state?.default_model;
    element("id-field").hidden = mode.value === "reset";
    id.disabled = busy || !state;
    element("load").hidden = !target?.discover;
    element("load").disabled = busy || listing || !state;
    element("refresh").disabled = busy;
    const next = selectedID();
    const changed = state && valid(next) && next !== state.current;
    element("apply").disabled = busy || pendingWork() || !changed;
    element("review").textContent = pendingWork() ? "Wait for the current work or pending decision to finish."
      : changed ? "Apply " + next + " to this session’s later tasks." : "";
  }

  async function read() {
    if (busy || !ticket) return;
    const request = ticket;
    busy = true;
    state = null;
    element("status").textContent = "Reading this OpenCode session…";
    draw();
    try {
      const result = await api(request.url + "?expected_core=" + encodeURIComponent(request.core));
      if (!sameTicket(request)) return;
      state = result;
      if (mode.value === "reset" && !state.default_model) mode.value = "select";
      element("status").textContent = "";
    } catch (error) {
      if (sameTicket(request)) element("status").textContent = error.message;
    } finally {
      if (sameTicket(request)) { busy = false; draw(); }
    }
  }

  launch.addEventListener("click", () => {
    if (!target || dialog.open) return;
    ticket = target;
    state = null;
    busy = false;
    listing = false;
    mode.value = "select";
    id.value = "";
    options.replaceChildren();
    dialog.showModal();
    void read();
  });
  element("close").addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => { ticket = null; state = null; busy = false; listing = false; });
  element("refresh").addEventListener("click", read);
  mode.addEventListener("change", draw);
  id.addEventListener("input", draw);

  element("load").addEventListener("click", async () => {
    if (!ticket?.template || listing || busy) return;
    const request = ticket;
    listing = true;
    element("status").textContent = "Reading OpenCode model IDs…";
    draw();
    try {
      const {models, truncated} = await api("/api/runtime-models/" + encodeURIComponent(request.template), {});
      if (!sameTicket(request)) return;
      options.replaceChildren(...models.map(({id}) => new Option(id, id)));
      element("status").textContent = models.length
        ? (truncated ? "Showing the first " : "Loaded ") + models.length + " model IDs. Listing does not test inference."
        : "The runtime did not list model IDs. You can type one.";
    } catch (error) {
      if (sameTicket(request)) element("status").textContent = error.message;
    } finally {
      if (sameTicket(request)) { listing = false; draw(); }
    }
  });

  element("form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const next = selectedID();
    if (!ticket || !state || busy || pendingWork() || !valid(next) || next === state.current) return;
    const request = ticket;
    const change = mode.value === "reset" ? { action: "reset" } : { action: "select", id: next };
    busy = true;
    element("status").textContent = "Applying the reviewed selection…";
    draw();
    try {
      const result = await api(request.url, {
        expected_core: request.core, expected_current: state.current, expected_default: state.default_model, change,
      });
      if (!sameTicket(request)) return;
      state = result;
      id.value = result.current || "";
      mode.value = "select";
      element("status").textContent = "OpenCode confirmed the model for later tasks.";
      element("status").focus();
    } catch (error) {
      if (!sameTicket(request)) return;
      state = null; // Force a fresh read; never offer an implicit retry.
      element("status").textContent = error.message + " Read the current selection before trying again.";
      element("status").focus();
    } finally {
      if (sameTicket(request)) { busy = false; draw(); }
    }
  });

  window.openCodeModels = {
    sync(agent, core, discover) {
      const allowed = Boolean(core && agent?.opencode_api && agent.state === "live" && !agent.reason);
      launch.hidden = !allowed;
      const url = allowed ? "/api/agents/" + encodeURIComponent(agent.address) + "/" + agent.created_ms + "/model" : null;
      if (target?.url !== url || target?.core !== core) {
        target = url ? { url, core, template: agent.template } : null;
        if (dialog.open) dialog.close();
      }
      if (target) {
        target.discover = Boolean(discover);
        target.status = agent.status?.state;
      }
      if (dialog.open) draw();
    },
  };
})();
