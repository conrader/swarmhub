import { setTimeout as sleep } from "node:timers/promises";

const voice = (id) => `document.getElementById("voice-memo-${id}")`;

// Observe real microphone streams; Chrome supplies deterministic synthetic audio.
export function observeVoiceStreams() {
  const capture = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  window.memoTestTracks = [];
  navigator.mediaDevices.getUserMedia = async (constraints) => {
    const stream = await capture(constraints);
    window.memoTestTracks.push(...stream.getTracks());
    return stream;
  };
}

export async function verifyVoiceMemos({evaluate, check}) {
  const click = (id) => evaluate(voice(id) + ".click()");
  const noStream = () => check('window.memoTestTracks.length > 0 && window.memoTestTracks.every(track => track.readyState === "ended")');
  const openDirect = async () => {
    const agent = '[...document.querySelectorAll("#agents button.agent")].find((item) => item.textContent.includes("voice-direct"))';
    await check(`!!${agent}`);
    await evaluate(agent + '.click()');
    await check('document.getElementById("title").textContent === "voice-direct"');
  };
  const recording = async (kind) => {
    await check(`!${voice(kind)}.hidden && !${voice(kind)}.disabled`);
    await click(kind);
    await click("start");
    await check(`!${voice("stop")}.hidden && window.memoTestTracks.at(-1)?.readyState === "live"`);
  };
  const attach = async () => {
    await sleep(700);
    await click("stop");
    await noStream();
    await check(`!${voice("playback")}.hidden && ${voice("playback")}.readyState >= 1`);
    await evaluate(`${voice("playback")}.muted = true; ${voice("playback")}.play().catch(() => {})`);
    await check(`${voice("playback")}.currentTime > 0`);
    await click("add");
    await check(`!${voice("dialog")}.open && !${voice("playback")}.hasAttribute("src")`);
  };
  const fill = (id, text) => evaluate(`{ const task = document.getElementById(${JSON.stringify(id)}); task.value = ${JSON.stringify(text)};
    task.dispatchEvent(new Event("input")); }`);
  const savedPreview = async (scope) => {
    const preview = `document.querySelector('${scope} [aria-label^="Preview Voice memo "]')`;
    await check(`!!${preview}`);
    await evaluate(preview + ".click()");
    await check('!document.getElementById("file-media-view").hidden && !document.getElementById("file-audio").hidden && document.getElementById("file-audio").readyState >= 1');
    await evaluate('document.getElementById("files-back").click()');
  };

  await openDirect();
  await fill("task", "Direct voice draft");
  await recording("direct");
  await attach();
  await check('document.querySelectorAll("#direct-draft-files li").length === 1 && document.getElementById("task").value === "Direct voice draft" && !document.querySelector(\'#tasks [aria-label^="Preview Voice memo "]\')');
  await recording("direct");
  await click("close");
  await noStream();
  await check('document.querySelectorAll("#direct-draft-files li").length === 1');

  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Voice memo group"))';
  await check(`!!${group}`);
  await recording("direct");
  await evaluate(group + ".click()");
  await noStream();
  await check(`!${voice("dialog")}.open && document.getElementById("title").textContent === "Voice memo group" && document.querySelectorAll("#group-draft-files li").length === 0`);
  await fill("group-task", "Group voice draft");
  await recording("group");
  await attach();
  await check('document.querySelectorAll("#group-draft-files li").length === 1 && !document.querySelector(\'#group-messages [aria-label^="Preview Voice memo "]\')');
  await evaluate('document.querySelector("#group-recipients input").click()');
  await check('!document.getElementById("group-send").disabled');
  await evaluate('document.getElementById("group-compose").requestSubmit()');
  await savedPreview("#group-messages");

  await openDirect();
  await check('document.getElementById("task").value === "Direct voice draft" && document.querySelectorAll("#direct-draft-files li").length === 1 && !document.getElementById("send").disabled');
  await evaluate('document.getElementById("composer").requestSubmit()');
  await savedPreview("#tasks");

  await recording("direct");
  await evaluate('app.token = "invalid-voice-fixture-token"; void refresh()');
  await noStream();
  await check(`!${voice("dialog")}.open && document.getElementById("core-status").textContent === "Workspace locked"`);
}
