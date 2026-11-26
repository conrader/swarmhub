(() => {
  "use strict";
  const open = document.getElementById("workspace-install-open");
  if (!open) return;
  const display = matchMedia("(display-mode: standalone)");
  const dialog = document.createElement("dialog");
  dialog.id = "workspace-install-dialog";
  dialog.setAttribute("aria-labelledby", "workspace-install-title");
  dialog.innerHTML = `<div class="details-header"><h2 id="workspace-install-title">Install SwarmHub</h2><button type="button" id="workspace-install-close" aria-label="Close installation help">Close</button></div>
    <p>Open this workspace from an app icon on your device. You’ll still use the same live workspace and access token.</p>
    <p><strong>iPhone or iPad:</strong> In Safari, open <b>Share</b> and choose <b>Add to Home Screen</b>. Turn on <b>Open as Web App</b> if shown, then choose <b>Add</b>.</p>
    <p><strong>Android:</strong> In Chrome, open the browser menu and choose <b>Install and create shortcut</b> or <b>Add to home screen</b>, then <b>Install</b> if offered.</p>
    <p class="subtle">Use a secure SwarmHub address that this device can reach. A localhost address on another computer won’t connect from your phone by itself. The installed app needs a connection to the workspace server. To get CI alerts after closing the app, open Activity and enable CI alerts on this device.</p>
    <p id="workspace-install-status" role="status" hidden></p>
    <div class="dialog-actions"><button type="button" id="workspace-install-prompt" class="primary" hidden>Install app</button></div>`;
  document.body.append(dialog);
  const prompt = document.getElementById("workspace-install-prompt");
  const status = document.getElementById("workspace-install-status");
  let request = null;
  let installed = false;

  function show(text) { status.textContent = text; status.hidden = !text; }
  function render() {
    open.hidden = installed || display.matches || navigator.standalone === true;
    prompt.hidden = !request || open.hidden;
  }

  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    request = event;
    render();
  });
  window.addEventListener("appinstalled", () => {
    request = null;
    installed = true;
    show("SwarmHub was installed.");
    render();
  });
  display.addEventListener("change", render);
  open.addEventListener("click", () => {
    if (dialog.open) return;
    show(window.isSecureContext ? "" : "Installation needs a secure browser context, such as HTTPS or localhost.");
    dialog.showModal();
  });
  document.getElementById("workspace-install-close").addEventListener("click", () => dialog.close());
  prompt.addEventListener("click", async () => {
    if (!request) return;
    const offer = request;
    request = null;
    render();
    try {
      await offer.prompt();
      const choice = await offer.userChoice;
      if (dialog.open && !installed) show(choice.outcome === "accepted" ? "Your browser accepted the install request."
        : "You can install later from your browser menu.");
    } catch {
      if (dialog.open && !installed) show("The install prompt is unavailable. Try your browser menu.");
    }
  });

  if (window.isSecureContext && "serviceWorker" in navigator) {
    navigator.serviceWorker.register("/workspace-sw.js", {scope:"/", updateViaCache:"none"}).catch(() => {
      // The live workspace still works if the browser does not allow workers.
    });
  }
  render();
})();
