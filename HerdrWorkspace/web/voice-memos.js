(() => {
  "use strict";
  const formats = [
    {codec:"audio/webm;codecs=opus", mime:"audio/webm", extension:"weba"},
    {codec:"audio/ogg;codecs=opus", mime:"audio/ogg", extension:"ogg"},
    {codec:"audio/mp4", mime:"audio/mp4", extension:"m4a"},
  ];
  const format = window.isSecureContext && navigator.mediaDevices?.getUserMedia && window.MediaRecorder
    && formats.find(({codec}) => MediaRecorder.isTypeSupported(codec));
  const buttons = {direct: $("voice-memo-direct"), group: $("voice-memo-group")};
  if (!format || !buttons.direct || !buttons.group) return;

  const limit = 1024 * 1024;
  const duration = 60_000;
  const dialog = document.createElement("dialog");
  dialog.id = "voice-memo-dialog";
  dialog.setAttribute("aria-labelledby", "voice-memo-title");
  dialog.innerHTML = `<div class="details-header"><h2 id="voice-memo-title">Voice memo</h2><button id="voice-memo-close" type="button">Discard</button></div>
    <p class="subtle">Record up to one minute. Listen before adding it to your draft. The audio stays in this tab until you send the message.</p>
    <p id="voice-memo-status" role="status" aria-atomic="true"></p>
    <p id="voice-memo-error" class="error" role="alert" hidden></p>
    <audio id="voice-memo-playback" controls preload="metadata" aria-label="Review your voice memo" hidden></audio>
    <div class="dialog-actions"><button id="voice-memo-start" type="button">Start recording</button><button id="voice-memo-stop" type="button" hidden>Stop recording</button><button id="voice-memo-add" class="primary" type="button" hidden>Add to draft</button></div>`;
  document.body.append(dialog);
  const start = $("voice-memo-start"), stop = $("voice-memo-stop"), add = $("voice-memo-add"), playback = $("voice-memo-playback");
  playback.style.maxWidth = "100%";
  let memo = null;

  function draft(kind) {
    return kind === "direct" ? voiceDirectDraft() : window.groupWorkspace?.voiceDraft();
  }

  function current(run) {
    return memo === run && dialog.open && app.token === run.token && draft(run.kind)?.key === run.key;
  }

  function render() {
    for (const [kind, button] of Object.entries(buttons)) {
      const target = draft(kind);
      button.hidden = !target;
      button.disabled = !target?.canAdd || target.bytes <= 0;
    }
    if (memo && !current(memo)) close();
    else if (memo?.file) {
      const target = draft(memo.kind);
      add.disabled = !target?.canAdd || memo.file.size > target.bytes;
    }
  }

  function phase(state, text) {
    start.hidden = !["ready", "review"].includes(state);
    start.textContent = state === "review" ? "Record again" : "Start recording";
    stop.hidden = state !== "recording";
    playback.hidden = add.hidden = state !== "review";
    $("voice-memo-status").textContent = text;
  }

  function stopTracks(run) {
    clearTimeout(run.timer);
    for (const track of run.stream?.getTracks() || []) track.stop();
    run.stream = null;
  }

  function release(run) {
    if (run?.recorder && run.recorder.state !== "inactive") run.recorder.stop();
    if (run) {
      stopTracks(run);
      run.file = null;
      run.chunks = [];
      run.bytes = 0;
    }
    if (!run?.url) return;
    playback.pause();
    playback.removeAttribute("src");
    playback.load();
    URL.revokeObjectURL(run.url);
    run.url = null;
  }

  function close() {
    const run = memo;
    memo = null;
    release(run);
    if (dialog.open) dialog.close();
  }

  function open(kind) {
    const target = draft(kind);
    if (dialog.open || !target?.canAdd || target.bytes <= 0) return;
    memo = {kind, key:target.key, token:app.token};
    show("voice-memo-error", "");
    phase("ready", "Microphone is off.");
    dialog.showModal();
    start.focus();
  }

  function fail(run, reason) {
    if (!current(run)) return;
    run.failed = true;
    release(run);
    phase("ready", "Microphone is off.");
    show("voice-memo-error", reason);
    start.focus();
  }

  function finish(run) {
    if (run.recorder?.state !== "recording") return;
    phase("stopping", "Preparing the recording…");
    run.recorder.stop();
    stopTracks(run);
  }

  async function record() {
    const previous = memo;
    if (!previous || !current(previous) || start.hidden) return;
    const target = draft(previous.kind);
    if (!target?.canAdd || target.bytes <= 0) return;
    const run = {kind:previous.kind, key:previous.key, token:previous.token, bytes:0, chunks:[], cap:Math.min(limit,target.bytes)};
    memo = run;
    release(previous);
    show("voice-memo-error", "");
    phase("requesting", "Waiting for microphone permission…");
    try {
      run.stream = await navigator.mediaDevices.getUserMedia({audio:{channelCount:{ideal:1}}, video:false});
      if (!current(run) || document.hidden) {
        stopTracks(run);
        if (current(run)) phase("ready", "Microphone is off. Start again when ready.");
        return;
      }
      const recorder = run.recorder = new MediaRecorder(run.stream, {mimeType:format.codec, audioBitsPerSecond:48_000});
      recorder.addEventListener("dataavailable", ({data}) => {
        if (!current(run) || run.failed || !data.size) return;
        run.bytes += data.size;
        if (run.bytes > run.cap) {
          fail(run, "This recording is too large for your draft. Try a shorter memo.");
          return;
        }
        run.chunks.push(data);
        if (run.bytes >= run.cap * 0.85) finish(run);
      });
      recorder.addEventListener("error", () => fail(run, "Recording stopped unexpectedly. Try again."));
      recorder.addEventListener("stop", () => {
        stopTracks(run);
        if (!current(run) || run.failed) return;
        if (!run.bytes) {
          fail(run, "No audio was recorded. Try again.");
          return;
        }
        const time = new Date().toISOString().slice(0,19).replace(/[T:]/g,"-");
        run.file = new File(run.chunks, `Voice memo ${time}.${format.extension}`, {type:format.mime});
        run.chunks = [];
        run.url = URL.createObjectURL(run.file);
        playback.src = run.url;
        phase("review", "Microphone is off. Listen to the recording, then add it to your draft.");
        render();
        if (!add.disabled) add.focus();
      }, {once:true});
      recorder.start(250);
      run.timer = setTimeout(() => finish(run), duration);
      phase("recording", "Recording… The microphone is on.");
      stop.focus();
    } catch (error) {
      fail(run, error.name === "NotAllowedError" ? "Microphone permission was denied. Allow it in the browser to record."
        : error.name === "NotFoundError" ? "No microphone was found." : "Could not start recording from this microphone.");
    }
  }

  for (const [kind, button] of Object.entries(buttons)) button.addEventListener("click", () => open(kind));
  start.addEventListener("click", record);
  stop.addEventListener("click", () => { if (memo) finish(memo); });
  $("voice-memo-close").addEventListener("click", close);
  dialog.addEventListener("cancel", (event) => { event.preventDefault(); close(); });
  dialog.addEventListener("close", () => { if (!dialog.open && memo) close(); });
  add.addEventListener("click", () => {
    const run = memo;
    if (!run?.file || !current(run)) return;
    const target = draft(run.kind);
    if (!target?.canAdd || run.file.size > target.bytes) return;
    const attached = run.kind === "direct" ? addDirectVoiceMemo(run.key, run.file)
      : window.groupWorkspace?.addVoiceMemo(run.key, run.file);
    if (attached) close();
    else show("voice-memo-error", "This recording no longer fits in the draft.");
  });
  document.addEventListener("visibilitychange", () => { if (document.hidden && memo) finish(memo); });
  window.addEventListener("pagehide", close);
  window.voiceMemos = {render};
  render();
})();
