(() => {
  "use strict";
  const dialog = $("runtime-setup");
  const recipes = Object.freeze({
    codex: { name:"codex.md", label:"Codex with saved replies", command:"swarmhub-herdr run-codex", quiet:true },
    claude: { name:"claude-code.md", label:"Claude Code with saved replies", command:"swarmhub-herdr run-claude", quiet:true },
    opencode: { name:"opencode.md", label:"OpenCode V2.3 session", command:"swarmhub-herdr run-opencode --api-first-task mini" },
    // No quiet readiness: Gemini CLI's hooks say when it is ready, and it may be showing its sign-in question.
    gemini: { name:"gemini-cli.md", label:"Gemini CLI (beta) with saved replies", command:"swarmhub-herdr run-gemini" },
    custom: { name:"custom-agent.md", label:"Replace your-agent with an installed interactive agent", command:"your-agent", quiet:true },
  });
  let signature;
  let refreshing = false;
  const list = $("runtime-setup-list");

  function recipe() {
    const selection = recipes[$("runtime-setup-kind").value] || recipes.codex;
    return { name:selection.name, text:[
      "---", "description: " + selection.label, "command: " + selection.command,
      ...(selection.quiet ? ["ready: quiet"] : []), "---", "",
    ].join("\n") };
  }

  function drawRecipe() {
    const selected = recipe();
    $("runtime-setup-example").value = selected.text;
    $("runtime-setup-download").textContent = "Download " + selected.name;
    show("runtime-setup-message", "");
  }

  function choose(template) {
    if (!app.authorized || !available() || !app.templates.some((item) => item.name === template && !item.error)) return;
    const current = window.agentProfiles.current();
    dialog.close();
    openLaunch(current && !current.sessions.length ? current : null, template);
  }

  function render() {
    $("runtime-setup-open").disabled = !app.authorized;
    for (const id of ["runtime-setup-welcome","runtime-setup-draft"]) {
      $(id).hidden = !app.authorized || available();
    }
    if (!dialog.open) return;
    if (!app.authorized) { dialog.close(); return; }
    $("runtime-setup-refresh").disabled = refreshing;
    const templates = app.online ? app.templates : [];
    const usable = templates.filter((item) => !item.error).length;
    let state = !app.online ? "Herdr Core is disconnected. You can still download a template example."
      : !templates.length ? "Herdr is connected, but no templates are installed."
      : !usable ? "Herdr is connected, but none of its templates can be used."
      : usable + (usable === 1 ? " template available." : " templates available.");
    if (app.online && usable && usable < templates.length) {
      const blocked = templates.length - usable;
      state += " " + blocked + (blocked === 1 ? " needs attention." : " need attention.");
    }
    if (refreshing) state = "Checking Herdr templates…";
    if ($("runtime-setup-state").textContent !== state) $("runtime-setup-state").textContent = state;
    list.hidden = !templates.length;
    const next = JSON.stringify(templates);
    if (signature === next) return;
    signature = next;
    list.replaceChildren(...templates.map((item) => {
      const row = document.createElement("li");
      if (!item.error) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = item.name;
        button.setAttribute("aria-label", "Choose " + item.name);
        button.addEventListener("click", () => choose(item.name));
        row.append(button);
      } else {
        const label = document.createElement("strong");
        label.textContent = item.name;
        row.append(label);
      }
      const detail = document.createElement("small");
      const runtime = item.runtime || {};
      detail.textContent = item.error ? item.error : [
        runtime.harness, runtime.provider, runtime.model || "Model set by agent", item.description,
      ].filter(Boolean).join(" · ");
      row.append(detail);
      return row;
    }));
  }

  function open() {
    if (!app.authorized || dialog.open) return;
    $("runtime-setup-recipes").open = !available();
    drawRecipe();
    dialog.showModal();
    render();
  }

  for (const id of ["runtime-setup-open", "runtime-setup-welcome", "runtime-setup-draft"]) $(id).addEventListener("click", open);
  $("runtime-setup-close").addEventListener("click", () => dialog.close());
  $("runtime-setup-kind").addEventListener("change", drawRecipe);
  $("runtime-setup-refresh").addEventListener("click", async () => {
    if (!dialog.open || !app.authorized || refreshing) return;
    refreshing = true;
    render();
    try { await refresh(); }
    finally { refreshing = false; render(); }
  });
  $("runtime-setup-download").addEventListener("click", () => {
    if (!dialog.open || !app.authorized) return;
    const {name,text} = recipe();
    const url = URL.createObjectURL(new Blob([text], {type:"text/markdown; charset=utf-8"}));
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    show("runtime-setup-message", "Download started. Save the template on the machine running Herdr.");
  });
  window.workspaceRuntimeSetup = { render };
  render();
})();
