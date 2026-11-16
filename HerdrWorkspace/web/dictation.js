(() => {
  "use strict";
  const buttons = {direct: $("dictate-direct"), group: $("dictate-group")};
  if (!buttons.direct || !buttons.group) return;
  const dialog = document.createElement("dialog");
  dialog.id = "dictation-dialog";
  dialog.setAttribute("aria-labelledby", "dictation-title");
  dialog.innerHTML = `<div class="details-header"><h2 id="dictation-title">Dictate on this device</h2><button id="dictation-close" type="button">Discard</button></div>
    <p class="subtle">Your browser recognizes speech on this device. Review the text before adding it to your draft.</p>
    <div id="dictation-language-controls"><label for="dictation-language">Dictation language</label>
      <input id="dictation-language" maxlength="64" placeholder="en-US" autocomplete="off" aria-describedby="dictation-language-help">
      <p class="subtle" id="dictation-language-help">Use a language tag such as en-US or pl-PL.</p>
    </div>
    <p id="dictation-status" role="status" aria-atomic="true"></p>
    <div id="dictation-review" hidden><label for="dictation-text">Transcript</label>
      <textarea id="dictation-text" rows="5" maxlength="16384" aria-describedby="dictation-review-help dictation-error"></textarea>
      <p class="subtle" id="dictation-review-help">Edit this text before adding it to the end of your draft.</p>
    </div>
    <p id="dictation-error" class="error" role="alert" hidden></p>
    <div class="dialog-actions compose-tools">
      <button type="button" id="dictation-check">Check availability</button><button type="button" id="dictation-prepare" hidden>Prepare language</button>
      <button type="button" id="dictation-start" class="primary" hidden>Start dictating</button><button type="button" id="dictation-stop" class="primary" hidden>Stop dictating</button>
      <button type="button" id="dictation-add" class="primary" hidden>Add to draft</button>
    </div>`;
  document.body.append(dialog);
  const get = (id) => $("dictation-" + id);
  const language = get("language"), transcript = get("text"), start = get("start"), stop = get("stop"), add = get("add");
  const encoder = new TextEncoder();
  let lastLanguage = navigator.language || "en-US";
  let activeRun = null;

  function localAPI() {
    if (!window.isSecureContext) return null;
    return [window.SpeechRecognition, window.webkitSpeechRecognition].find((api) => typeof api === "function"
      && typeof api.available === "function" && "processLocally" in api.prototype) || null;
  }

  function draft(kind) {
    return kind === "direct" ? directDictationDraft() : window.groupWorkspace?.dictationDraft();
  }

  function current(run) {
    return activeRun === run && dialog.open && app.token === run.token && draft(run.kind)?.key === run.key;
  }

  function controls(run) {
    const busy = run.checking || run.preparing || run.speech;
    get("language-controls").hidden = !run.api;
    language.disabled = Boolean(busy);
    get("check").hidden = !run.api || Boolean(run.speech);
    get("check").disabled = Boolean(busy);
    get("prepare").hidden = run.available !== "downloadable" || typeof run.api?.install !== "function" || Boolean(run.speech);
    get("prepare").disabled = Boolean(busy);
    start.hidden = run.available !== "available" || Boolean(run.speech);
    start.disabled = Boolean(busy) || !draft(run.kind)?.canEdit;
    start.textContent = run.review ? "Dictate again" : "Start dictating";
    stop.hidden = !run.speech;
    stop.disabled = Boolean(run.speech?.ending);
    get("review").hidden = !run.review;
    transcript.readOnly = Boolean(run.speech);
    add.hidden = !run.review || Boolean(run.speech);
    add.disabled = !transcript.value.trim() || !draft(run.kind)?.canEdit;
  }

  function render() {
    for (const [kind, button] of Object.entries(buttons)) {
      const target = draft(kind);
      button.hidden = !target;
      button.disabled = !target?.canEdit;
    }
    if (activeRun && !current(activeRun)) close();
    else if (activeRun) controls(activeRun);
  }

  function notice(value) { get("status").textContent = value; }
  function error(value) { show("dictation-error", value); }

  function options() {
    try {
      const [code] = Intl.getCanonicalLocales(language.value.trim());
      return code ? {langs:[code], processLocally:true, quality:"dictation"} : null;
    } catch { return null; }
  }

  function describe(run) {
    switch (run.available) {
      case "available": return "This language is ready for on-device dictation.";
      case "downloadable": return typeof run.api.install === "function"
        ? "Prepare this language before dictating. Your browser may download a language pack."
        : "This language needs an on-device pack that this browser cannot prepare here.";
      case "downloading": return "Your browser is preparing this language. Check again when it finishes.";
      default: return "On-device dictation is unavailable for this language. You can check another language.";
    }
  }

  async function check(run) {
    if (!current(run) || !run.api || run.checking || run.preparing || run.speech) return;
    const request = options();
    run.available = null;
    run.lang = null;
    error("");
    if (!request) {
      error("Enter a language tag such as en-US or pl-PL.");
      controls(run);
      return;
    }
    lastLanguage = request.langs[0];
    run.checking = true;
    notice("Checking whether your browser can dictate in this language…");
    controls(run);
    try {
      run.available = await run.api.available(request);
      if (!current(run)) return;
      run.lang = request.langs[0];
      notice(describe(run));
    } catch {
      if (current(run)) notice("This browser could not check on-device dictation. No microphone was opened.");
    } finally {
      run.checking = false;
      if (current(run)) controls(run);
    }
  }

  async function prepare() {
    const run = activeRun;
    if (!run || !current(run) || run.available !== "downloadable" || typeof run.api.install !== "function"
      || run.preparing || run.checking || run.speech) return;
    const request = options();
    if (request?.langs[0] !== run.lang) return;
    run.preparing = true;
    notice("Your browser is preparing this language…");
    controls(run);
    try {
      const installed = await run.api.install(request);
      if (!current(run)) return;
      if (!installed) throw new Error("Language preparation failed");
      run.preparing = false;
      await check(run);
    } catch {
      if (current(run)) notice("Your browser could not prepare this language. Try checking again.");
    } finally {
      run.preparing = false;
      if (current(run)) controls(run);
    }
  }

  function dispose(speech) {
    clearTimeout(speech.timer);
    clearTimeout(speech.endTimer);
    try { speech.recognition.abort(); } catch { /* The browser may have ended it already. */ }
  }

  function close() {
    const run = activeRun;
    activeRun = null;
    if (run?.speech) dispose(run.speech);
    transcript.value = "";
    if (dialog.open) dialog.close();
  }

  function open(kind) {
    const target = draft(kind);
    if (!target?.canEdit || dialog.open) return;
    const run = activeRun = {kind, key:target.key, token:app.token, api:localAPI()};
    language.value = lastLanguage;
    transcript.value = "";
    error("");
    controls(run);
    dialog.showModal();
    if (run.api) {
      void check(run);
      get("close").focus();
    } else {
      notice(window.isSecureContext ? "This browser does not support on-device dictation here. You can still type your draft."
        : "On-device dictation requires a secure browser context, such as localhost.");
    }
  }

  function finish(run, speech, note, abort = false) {
    if (!current(run) || run.speech !== speech) return;
    run.speech = null;
    clearTimeout(speech.timer);
    clearTimeout(speech.endTimer);
    if (abort) dispose(speech);
    notice(note || (transcript.value.trim() ? "Microphone is off. Review the transcript before adding it to your draft."
      : "Microphone is off. No speech was recognized."));
    controls(run);
    if (transcript.value.trim()) transcript.focus();
    else if (!start.hidden && !start.disabled) start.focus();
  }

  function stopListening() {
    const run = activeRun, speech = run?.speech;
    if (!speech || speech.ending || !current(run)) return;
    speech.ending = true;
    clearTimeout(speech.timer);
    notice("Finishing on-device recognition…");
    controls(run);
    speech.endTimer = setTimeout(() => finish(run, speech, "Microphone is off. Review any recognized text.", true), 2500);
    try { speech.recognition.stop(); } catch { finish(run, speech, null, true); }
  }

  function listen() {
    const run = activeRun;
    if (!run || !current(run) || !draft(run.kind)?.canEdit || run.speech || run.available !== "available"
      || options()?.langs[0] !== run.lang || document.hidden) return;
    let speech;
    error("");
    try {
      const recognition = new run.api();
      recognition.processLocally = true;
      if (recognition.processLocally !== true) throw new Error("This browser could not require local recognition");
      recognition.lang = run.lang;
      recognition.continuous = true;
      recognition.interimResults = true;
      speech = run.speech = {recognition};
      run.review = true;
      transcript.value = "";
      const running = () => current(run) && run.speech === speech;
      recognition.addEventListener("start", () => { if (running() && !speech.ending) notice("Listening on this device…"); });
      recognition.addEventListener("result", (event) => {
        if (!running()) return;
        // Results include earlier finalized text plus the browser’s latest tentative text.
        const parts = [];
        let bytes = 0;
        for (let i = 0; i < Math.min(128, event.results.length); i++) {
          const part = event.results[i][0]?.transcript?.trim().slice(0, 16384);
          if (!part) continue;
          bytes += encoder.encode(part).length + 1;
          if (bytes > 16 * 1024) break;
          parts.push(part);
        }
        transcript.value = parts.join(" ");
        if (bytes >= 16 * 1024) stopListening();
      });
      recognition.addEventListener("end", () => finish(run, speech));
      recognition.addEventListener("error", (event) => {
        if (!running()) return;
        const detail = ({"not-allowed":"Allow microphone access in the browser to dictate.",
          "audio-capture":"The browser could not open a microphone.", "no-speech":"No speech was recognized.",
          "language-not-supported":"The browser could not use this on-device language. Check availability again."})[event.error]
          || "On-device recognition stopped. No remote recognition was requested.";
        if (event.error === "language-not-supported") run.available = null;
        finish(run, speech, "Microphone is off.", true);
        error(detail);
      });
      notice("Waiting for the browser’s microphone…");
      controls(run);
      speech.timer = setTimeout(stopListening, 60_000);
      recognition.start();
      stop.focus();
    } catch {
      if (speech) finish(run, speech, "Microphone is off.", true);
      error("This browser could not start on-device dictation. No remote recognition was requested.");
    }
  }

  for (const [kind, button] of Object.entries(buttons)) button.addEventListener("click", () => open(kind));
  get("close").addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); close(); });
  dialog.addEventListener("close", () => { if (!dialog.open && activeRun) close(); });
  get("check").addEventListener("click", () => { if (activeRun) void check(activeRun); });
  get("prepare").addEventListener("click", prepare);
  language.addEventListener("input", () => {
    if (!activeRun) return;
    activeRun.available = null;
    activeRun.lang = null;
    notice("Check availability for this language.");
    error("");
    controls(activeRun);
  });
  start.addEventListener("click", listen);
  stop.addEventListener("click", stopListening);
  transcript.addEventListener("input", () => { if (activeRun) { error(""); controls(activeRun); } });
  add.addEventListener("click", () => {
    const run = activeRun;
    if (!run || run.speech || !current(run)) return;
    const target = draft(run.kind), text = transcript.value.trim();
    if (!target?.canEdit || !text) return;
    const result = target.field.value.trim() ? `${target.field.value}\n\n${text}` : target.field.value + text;
    if (encoder.encode(result).length > target.limit || /[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/u.test(text)) {
      error(`Keep the draft within ${target.limit / 1024} KiB and use plain text.`);
      transcript.focus();
      return;
    }
    target.field.value = result;
    target.field.dispatchEvent(new Event("input", {bubbles:true}));
    close();
    target.field.focus();
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && activeRun?.speech) finish(activeRun, activeRun.speech, "Microphone is off because this tab was hidden.", true);
  });
  window.addEventListener("pagehide", close);
  window.dictation = {render};
  render();
})();
