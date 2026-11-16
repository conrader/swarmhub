(() => {
  "use strict";
  const el = (id) => document.getElementById(id);
  const dialog = el("reaction-dialog");
  const close = el("reaction-close");
  const remove = el("reaction-remove");
  const status = el("reaction-status");
  const choices = new Map([
    ["like", ["👍", "Like"]], ["thanks", ["🙏", "Thanks"]],
    ["celebrate", ["🎉", "Celebrate"]], ["eyes", ["👀", "Looking"]],
  ]);
  const views = new WeakMap();
  const options = new Map();
  let active = null;
  let saving = false;

  function paint(button, reaction) {
    const choice = choices.get(reaction);
    button.dataset.selected = String(Boolean(choice));
    button.textContent = choice ? choice.join(" ") : "React";
    button.setAttribute("aria-label", choice ? "Change reaction: " + choice[1] : "React to message");
  }

  function message(text) {
    status.textContent = text;
    status.hidden = !text;
  }

  async function save(reaction, trigger) {
    if (!active || saving) return;
    const { route } = active;
    const controls = [close, remove, ...options.values()];
    saving = true;
    for (const control of controls) control.disabled = true;
    message("Saving reaction…");
    try {
      const saved = await api(route, {reaction});
      for (const button of document.querySelectorAll(".message-reaction")) {
        if (button.dataset.reactionRoute !== route) continue;
        views.get(button).reaction = saved.reaction;
        paint(button, saved.reaction);
      }
      dialog.close();
    } catch (error) {
      message(error.status ? error.message : "Couldn’t confirm the reaction. Try again.");
    } finally {
      saving = false;
      for (const control of controls) control.disabled = false;
      if (dialog.open) trigger.focus();
    }
  }

  for (const [key, choice] of choices) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = choice.join(" ");
    button.setAttribute("aria-label", choice[1]);
    button.addEventListener("click", () => { void save(key, button); });
    options.set(key, button);
    el("reaction-options").append(button);
  }
  close.addEventListener("click", () => { if (!saving) dialog.close(); });
  remove.addEventListener("click", () => { void save("remove", remove); });
  dialog.addEventListener("cancel", (event) => { if (saving) event.preventDefault(); });
  dialog.addEventListener("close", () => {
    if (dialog.open || !active) return;
    const { route, trigger, container } = active;
    active = null;
    const focus = trigger.isConnected ? trigger : find(container, route);
    focus?.focus({preventScroll:true});
  });

  function find(container, route) {
    return container && [...container.querySelectorAll(".message-reaction")].find((button) => button.dataset.reactionRoute === route);
  }

  function button(entry, path) {
    const control = document.createElement("button");
    control.type = "button";
    control.className = "message-reaction";
    control.dataset.reactionRoute = path + "/" + entry.id + "/reaction";
    control.setAttribute("aria-haspopup", "dialog");
    views.set(control, entry);
    paint(control, entry.reaction);
    control.addEventListener("click", () => {
      if (dialog.open) return;
      active = {route:control.dataset.reactionRoute, trigger:control, container:control.closest("#tasks,#group-messages,#archive-items,#direct-thread-root,#direct-thread-items")};
      const selected = entry.reaction;
      for (const [key, option] of options) option.setAttribute("aria-pressed", String(key === selected));
      remove.hidden = !choices.has(selected);
      message("");
      dialog.showModal();
      (options.get(selected) || options.get("like")).focus();
    });
    return control;
  }

  function replaceRows(container, rows) {
    const focused = document.activeElement;
    const route = container.contains(focused) ? focused.dataset.reactionRoute : null;
    container.replaceChildren(...rows);
    if (route) find(container, route)?.focus({preventScroll:true});
  }

  window.messageReactions = {button, replaceRows};
})();
