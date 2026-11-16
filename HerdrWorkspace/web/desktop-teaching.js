(() => {
  "use strict";
  const clickLimit = 24;
  const timeLimit = 120_000;
  const names = ["Left", "Middle", "Right"];

  function create(dialog, screen, detach) {
    const panel = document.createElement("section");
    panel.id = "desktop-teaching";
    panel.setAttribute("aria-label", "Teach a task");
    panel.innerHTML = `<div id="desktop-teach-actions" class="compose-tools">
      <button type="button" id="desktop-teach-open">Teach a task</button>
      <button type="button" id="desktop-teach-start" class="primary" hidden>Start recording</button>
      <button type="button" id="desktop-teach-stop" class="primary" hidden>Stop recording</button>
      <button type="button" id="desktop-teach-skill" class="primary" hidden>Review as skill</button>
      <button type="button" id="desktop-teach-discard" hidden>Discard sample</button>
    </div>
    <p id="desktop-teach-status" role="status" aria-atomic="true" hidden></p>
    <div id="desktop-teach-intro" hidden>
      <p class="subtle">Demonstrate with a mouse. The sample keeps up to 24 clicks in two minutes: each button and its position. It does not capture your screen, keyboard, clipboard, or drags. Stop before signing in or handling secrets.</p>
      <label for="desktop-teach-goal">What are you demonstrating? (optional)</label>
      <input id="desktop-teach-goal" maxlength="180" placeholder="For example, open the weekly report">
    </div>
    <div id="desktop-teach-review" hidden>
      <h3 id="desktop-teach-heading" tabindex="-1">Review your clicks</h3>
      <p class="subtle">Label what each click does so someone can follow the workflow if the screen layout changes. Remove any clicks you don’t want to keep.</p>
      <ol id="desktop-teach-steps"></ol>
    </div>`;
    screen.before(panel);
    const get = (name) => panel.querySelector("#desktop-teach-" + name);
    const buttons = Object.fromEntries(["open", "start", "stop", "skill", "discard"].map((name) => [name, get(name)]));
    let connection = null;
    let phase = "idle";
    let clicks = [];
    let listener = null;
    let timer = 0;
    let pressed = null;
    let goal = "";

    function active() { return Boolean(connection?.controlling() && dialog.open); }
    function message(text) { get("status").textContent = text; get("status").hidden = !text; }
    function render() {
      panel.hidden = !active();
      buttons.open.hidden = phase !== "idle";
      buttons.start.hidden = phase !== "intro";
      buttons.stop.hidden = phase !== "recording";
      buttons.discard.hidden = phase === "idle";
      buttons.skill.hidden = phase !== "review" || !clicks.length;
      get("intro").hidden = phase !== "intro";
      get("review").hidden = phase !== "review";
      screen.hidden = phase === "review";
    }

    function stopListening() {
      listener?.abort();
      listener = null;
      clearTimeout(timer);
      pressed = null;
    }

    function discard() {
      stopListening();
      phase = "idle";
      clicks = [];
      goal = "";
      get("goal").value = "";
      get("steps").replaceChildren();
      message("");
      render();
    }

    function bind(canvas = null, controlling = null, validReview = null) {
      connection = canvas ? {canvas, controlling, validReview} : null;
      discard();
    }

    function point(canvas, event) {
      const box = canvas.getBoundingClientRect();
      const u = (event.clientX - box.left) / box.width;
      const v = (event.clientY - box.top) / box.height;
      if (!canvas.width || !canvas.height || !(u >= 0 && u < 1 && v >= 0 && v < 1)) return null;
      return {x:Math.floor(u * canvas.width), y:Math.floor(v * canvas.height), width:canvas.width, height:canvas.height};
    }

    function plain(value, size) {
      return value.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim().slice(0, size);
    }

    function describe(step) { return `${names[step.button]} click at (${step.x}, ${step.y}) on ${step.width} × ${step.height}`; }
    function list() {
      get("steps").replaceChildren(...clicks.map((step, index) => {
        const row = document.createElement("li");
        const label = document.createElement("label");
        const field = document.createElement("input");
        const remove = document.createElement("button");
        field.id = `desktop-teach-label-${index}`;
        field.maxLength = 64;
        field.placeholder = "Add a step label";
        field.value = step.label;
        field.addEventListener("input", () => { step.label = plain(field.value, 64); });
        label.htmlFor = field.id;
        label.textContent = `${describe(step)} · Step label`;
        remove.type = "button";
        remove.textContent = "Remove";
        remove.setAttribute("aria-label", `Remove step ${index + 1}`);
        remove.addEventListener("click", () => {
          clicks.splice(index,1);
          list();
          render();
          if (!clicks.length) message("No clicks remain. Discard this sample to start again.");
          (get("label-" + Math.min(index, clicks.length - 1)) || buttons.discard).focus();
        });
        row.append(label,field,remove);
        return row;
      }));
    }

    function finish(note = "") {
      if (!active() || phase !== "recording") return;
      stopListening();
      phase = "review";
      list();
      render();
      message(clicks.length ? note || `Recorded ${clicks.length} ${clicks.length === 1 ? "click" : "clicks"}.`
        : "No clicks were recorded. Discard this sample to start again.");
      get("heading").focus();
    }

    buttons.open.addEventListener("click", () => {
      if (!active() || phase !== "idle") return;
      phase = "intro";
      render();
      get("goal").focus();
    });
    buttons.discard.addEventListener("click", () => { discard(); if (active()) buttons.open.focus(); });
    buttons.start.addEventListener("click", () => {
      if (!active() || phase !== "intro" || !connection.canvas.width) return;
      const canvas = connection.canvas;
      goal = plain(get("goal").value,180);
      phase = "recording";
      render();
      message(`Recording clicks · 0 of ${clickLimit}`);
      buttons.stop.focus();
      listener = new AbortController();
      const options = {capture:true, passive:true, signal:listener.signal};
      const trusted = (event) => active() && event.isTrusted && event.pointerType === "mouse";
      const moved = (event) => Math.hypot(event.clientX - pressed.cx, event.clientY - pressed.cy) > 5;
      // noVNC handles the generated mouse events itself. Observe the browser's
      // pointer events without capturing, preventing, or forwarding any input.
      window.addEventListener("pointerdown", (event) => {
        pressed = null;
        if (!trusted(event) || event.target !== canvas || !names[event.button] || !point(canvas,event)) return;
        pressed = {id:event.pointerId, button:event.button, cx:event.clientX, cy:event.clientY, dragged:false};
      }, options);
      window.addEventListener("pointermove", (event) => {
        if (pressed && trusted(event) && event.pointerId === pressed.id && moved(event)) pressed.dragged = true;
      }, options);
      window.addEventListener("pointercancel", () => { pressed = null; }, options);
      window.addEventListener("pointerup", (event) => {
        const accept = pressed && trusted(event) && event.pointerId === pressed.id && event.button === pressed.button
          && !pressed.dragged && !moved(event);
        pressed = null;
        if (!accept) return;
        const position = point(canvas,event);
        if (!position) return;
        clicks.push({...position, button:event.button, label:""});
        if (clicks.length === clickLimit) {
          stopListening();
          // Let the corresponding mouseup reach noVNC before hiding the canvas.
          timer = setTimeout(() => finish(`Reached the ${clickLimit}-click limit.`),0);
        }
        else message(`Recording clicks · ${clicks.length} of ${clickLimit}`);
      }, options);
      timer = setTimeout(() => finish("Reached the two-minute limit."), timeLimit);
    });
    buttons.stop.addEventListener("click", () => finish());
    buttons.skill.addEventListener("click", () => {
      if (!active() || phase !== "review" || !clicks.length) return;
      const draft = {
        name:"Demonstrated workflow", summary:"Steps reviewed from a private desktop demonstration.",
        instructions: [goal ? `Goal: ${goal}` : "Describe the workflow’s goal and when to use it.",
          "These clicks illustrate a workflow. Confirm the current screen and use the step labels to adapt the instructions when the layout changes.",
          ...clicks.map((step,index) => `${index + 1}. ${describe(step)}${step.label ? ` — ${step.label}` : ""}.`),
        ].join("\n\n"),
      };
      if (window.workspaceSkills?.reviewDemonstration?.(draft,connection.validReview)) detach();
      else message("The skill editor could not be opened. You can try again or discard the sample.");
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden && phase === "recording") discard();
    });
    window.addEventListener("pagehide", () => bind());
    render();
    return {bind};
  }

  window.desktopTeaching = {create};
})();
