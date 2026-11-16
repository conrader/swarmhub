(() => {
  "use strict";
  const key = "swarmhub-appearance-v1";
  const modes = new Set(["system", "light", "dark"]);
  const colors = {light:"#f4f5fa", dark:"#16181e"};
  const root = document.documentElement;
  const themeColor = document.querySelector('meta[name="theme-color"]');
  const system = matchMedia("(prefers-color-scheme: dark)");
  let setting = "system";
  let form;
  let status;
  function valid(value) { return modes.has(value) ? value : "system"; }
  function read() {
    try { return valid(localStorage.getItem(key)); } catch { return "system"; }
  }
  function apply() {
    const theme = setting === "system" ? (system.matches ? "dark" : "light") : setting;
    root.dataset.appearance = theme;
    root.style.colorScheme = theme;
    root.style.backgroundColor = colors[theme];
    themeColor?.setAttribute("content", colors[theme]);
    if (form) {
      form.elements.mode.value = setting;
      const text = setting === "system" ? `Following the device theme (${theme}).` : `Using ${theme} on this device.`;
      if (status.textContent !== text) status.textContent = text;
    }
  }
  // The small script runs in the head before stylesheet discovery and paint.
  setting = read();
  apply();
  system.addEventListener("change", () => { if (setting === "system") apply(); });
  window.addEventListener("storage", (event) => {
    if (event.key === key || event.key === null) {
      setting = read();
      apply();
    }
  });

  function setup() {
    const open = document.getElementById("appearance-open");
    if (!open) return;
    const dialog = document.createElement("dialog");
    dialog.id = "appearance-dialog";
    dialog.setAttribute("aria-labelledby", "appearance-heading");
    dialog.innerHTML = `<div class="details-header"><h2 id="appearance-heading">Appearance</h2><button type="button" id="appearance-close">Close</button></div>
      <p>This setting applies in this browser and is separate from your workspace account.</p>
      <form id="appearance-form">
        <fieldset><legend>Theme</legend>
          <label><input name="mode" type="radio" value="system"><span>System<small>Follow your device’s theme</small></span></label>
          <label><input name="mode" type="radio" value="light"><span>Light</span></label>
          <label><input name="mode" type="radio" value="dark"><span>Dark</span></label>
        </fieldset>
      </form><p id="appearance-status" role="status"></p>`;
    document.body.append(dialog);
    form = document.getElementById("appearance-form");
    status = document.getElementById("appearance-status");
    form.addEventListener("change", () => {
      setting = valid(form.elements.mode.value);
      try { localStorage.setItem(key, setting); } catch { /* The current tab can still switch themes. */ }
      apply();
    });
    form.addEventListener("submit", (event) => event.preventDefault());
    open.addEventListener("click", () => {
      if (dialog.open) return;
      dialog.showModal();
      form.querySelector(":checked")?.focus();
    });
    document.getElementById("appearance-close").addEventListener("click", () => dialog.close());
    apply();
    open.hidden = false;
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", setup, {once:true});
  else setup();
})();
