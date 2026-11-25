import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { observeVoiceStreams, verifyVoiceMemos } from "./voice-memos-browser.mjs";

const [chrome, origin, token, temp] = process.argv.slice(2);
const focus = process.env.SWARMHUB_TEST_FOCUS;
const profile = await mkdtemp(join(temp, "chrome-"));
const child = spawn(chrome, ["--headless", "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu", "--disable-background-networking",
  "--remote-debugging-port=0", "--window-size=1440,900", "--no-first-run", "--no-default-browser-check",
  ...(focus === "voice-memos" ? ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"] : []),
  "--no-proxy-server", `--user-data-dir=${profile}`, "about:blank"], {
  stdio: ["ignore", "ignore", "pipe"],
  env: { PATH: process.env.PATH, HOME: temp, TMPDIR: temp, XDG_CONFIG_HOME: join(temp, "chrome-config"),
    XDG_CACHE_HOME: join(temp, "chrome-cache"), DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(temp, "no-dbus")}` },
});
let chromeError = "";
child.stderr.on("data", (chunk) => { chromeError = (chromeError + chunk).slice(-4000); });
child.on("error", (error) => { chromeError += error.message; });
let ws;
const pending = new Map();
let next = 0;

async function waitFor(condition, error, attempts = 150) {
  for (let i = 0; i < attempts; ++i) {
    const value = await condition();
    if (value) return value;
    await sleep(100);
  }
  throw new Error(error);
}

function cdp(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, sessionId }));
  });
}

async function evaluate(expression, sessionId) {
  const { result, exceptionDetails } = await cdp("Runtime.evaluate", { expression, returnByValue: true, userGesture: true }, sessionId);
  if (exceptionDetails) throw new Error(exceptionDetails.exception?.description || exceptionDetails.text);
  return result.value;
}

const check = (expression) => waitFor(() => evaluate(expression), `Browser assertion failed: ${expression}`);

async function verifyApproval() {
  const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
  await evaluate(`const input = document.getElementById("task");
    input.value = "approval from browser";
    input.dispatchEvent(new Event("input"));
    document.getElementById("composer").requestSubmit()`);
  await check('!document.getElementById("approval-count").hidden');
  await evaluate('document.getElementById("approvals-open").click()');
  await check('document.querySelector("#approval-list button")?.textContent.includes("browser-test")');
  await evaluate('document.querySelector("#approval-list button").click()');
  await check('document.getElementById("approval-input").textContent.includes("printf fixture") && document.getElementById("approval-input").textContent.includes("9007199254740993")');
  if (focus === "codex") await check('document.getElementById("approval-path").textContent.startsWith("Codex ·")');
  if (screenshot) {
    const { data } = await cdp("Page.captureScreenshot", { format: "png" });
    await writeFile(screenshot.replace(/\.png$/, focus === "codex" ? "-codex-approval.png" : "-approval.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.getElementById("approval-allow").click()');
  await check('document.getElementById("approval-history").textContent.includes("browser-test") && document.getElementById("approval-history").textContent.includes("Allow once sent")');
  await evaluate('document.getElementById("approval-close").click()');
}

async function verifySkills() {
  await check('document.querySelector("#tasks .reply-item button")?.textContent === "Save as skill"');
  await evaluate('document.querySelector("#tasks .reply-item button").click()');
  await check('document.getElementById("skill-text").value.includes("Structured reply for browser first task")');
  await evaluate(`document.getElementById("skill-name").value = "Browser review";
    document.getElementById("skill-description").value = "When a report needs review";
    document.getElementById("skill-text").value = "Inspect the supplied report.";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-version").textContent === "Version 1"');
  await evaluate('document.getElementById("skill-edit").click()');
  await evaluate(`document.getElementById("skill-text").value = "Inspect the supplied report and list issues.";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-version").textContent === "Version 2"');
  const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
  if (screenshot) {
    const { data } = await cdp("Page.captureScreenshot", { format: "png" });
    await writeFile(screenshot.replace(/\.png$/, "-skills.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.getElementById("skill-close").click(); document.getElementById("task-skill").click()');
  await check('document.getElementById("skill-list").textContent.includes("Browser review")');
  const pick = 'Array.from(document.querySelectorAll("#skill-list button")).find(button => button.textContent.startsWith("Browser review")).click()';
  await evaluate(pick);
  await check('!document.getElementById("skill-use").disabled');
  await evaluate('document.getElementById("skill-use").click()');
  await check('!document.getElementById("skill-dialog").open && document.getElementById("task").value.includes("Skill: Browser review (version 2)")');
  await check('!document.getElementById("output").textContent.includes("Inspect the supplied report")');
  await evaluate('document.getElementById("routines-open").click()');
  await check('!document.getElementById("routine-new").disabled');
  await evaluate('document.getElementById("routine-new").click(); document.getElementById("routine-skill").click()');
  await check('document.getElementById("skill-list").textContent.includes("Browser review")');
  await evaluate(pick);
  await check('!document.getElementById("skill-use").disabled');
  await evaluate('document.getElementById("skill-use").click()');
  await check('document.getElementById("routine-task").value.includes("Skill: Browser review (version 2)")');
  await evaluate(`document.getElementById("routine-name").value = "Skill routine";
    document.getElementById("routine-form").requestSubmit()`);
  await check('document.getElementById("routine-instructions").textContent.includes("Inspect the supplied report and list issues.")');
  await evaluate('document.getElementById("routine-close").click(); document.getElementById("skills-open").click()');
  await check('document.getElementById("skill-list").textContent.includes("Browser review")');
  await evaluate(pick);
  await check('!document.getElementById("skill-edit").disabled');
  await evaluate(`document.getElementById("skill-edit").click();
    document.getElementById("skill-text").value = "A later revision.";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-version").textContent === "Version 3"');
  await evaluate('document.getElementById("skill-close").click(); document.getElementById("routines-open").click()');
  await check('document.getElementById("routine-list").textContent.includes("Skill routine")');
  await evaluate('Array.from(document.querySelectorAll("#routine-list button")).find(button => button.textContent.startsWith("Skill routine")).click()');
  await check('document.getElementById("routine-instructions").textContent.includes("Skill: Browser review (version 2)") && !document.getElementById("routine-instructions").textContent.includes("A later revision.")');
  await evaluate('document.getElementById("routine-close").click()');

  const markdown = join(temp, "handoff.md");
  const instructions = "# Handoff checklist\n\nConfirm the inputs and write a short note.\n";
  await writeFile(markdown, instructions.replace(/\n/g, "\r\n"));
  await evaluate('document.getElementById("skills-open").click()');
  const { root } = await cdp("DOM.getDocument");
  const { nodeId } = await cdp("DOM.querySelector", {nodeId: root.nodeId, selector: "#skill-file"});
  const chooseSkill = (path) => cdp("DOM.setFileInputFiles", {nodeId, files: [path]});
  await chooseSkill(markdown);
  await check('document.getElementById("skill-heading").textContent === "Review imported skill" && document.getElementById("skill-name").value === "Handoff checklist" && document.activeElement.id === "skill-name"');
  assert.equal(await evaluate('document.getElementById("skill-text").value'), instructions);
  await evaluate('document.getElementById("skill-cancel").click()');
  await check('document.getElementById("skill-list").textContent.includes("Browser review") && !document.getElementById("skill-list").textContent.includes("Handoff checklist")');
  const invalid = join(temp, "not-a-skill.json");
  await writeFile(invalid, '{"name":"An unrelated JSON file"}');
  await chooseSkill(invalid);
  await check('document.getElementById("skill-import-status").textContent.includes("isn’t a SwarmHub skill copy") && !document.getElementById("skill-import").disabled');
  await chooseSkill(markdown);
  await check('!document.getElementById("skill-form").hidden');
  await evaluate(`document.getElementById("skill-description").value = "At the end of a shift";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-heading").textContent === "Handoff checklist" && !document.getElementById("skill-download").disabled');
  const downloads = join(temp, "skill downloads");
  const copy = join(downloads, "handoff-checklist.swarmhub-skill.json");
  await cdp("Page.setDownloadBehavior", {behavior: "allow", downloadPath: downloads});
  await evaluate('document.getElementById("skill-download").click()');
  assert.deepEqual(JSON.parse(await waitFor(() => readFile(copy, "utf8").catch(() => ""), "Skill copy download failed")), {
    format: "swarmhub-skill/v1", name: "Handoff checklist", summary: "At the end of a shift", instructions,
  });
  await evaluate('document.getElementById("skill-back").click()');
  await chooseSkill(copy);
  await check('document.getElementById("skill-heading").textContent === "Review imported skill" && document.getElementById("skill-description").value === "At the end of a shift"');
  await evaluate(`document.getElementById("skill-name").value = "Handoff copy";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-heading").textContent === "Handoff copy" && document.getElementById("skill-version").textContent === "Version 1"');
  await evaluate('document.getElementById("skill-back").click()');
  await check('["Handoff checklist", "Handoff copy"].every(name => document.getElementById("skill-list").textContent.includes(name))');
  await evaluate('document.getElementById("skill-close").click()');
}

async function verifyGroups() {
  const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
  await check('!document.getElementById("new-group").disabled');
  await evaluate(`document.getElementById("new-group").click();
    document.getElementById("group-name").value = "Browser group";
    for (const row of document.querySelectorAll("#group-options label")) {
      if (["browser-test", "claude-capture"].includes(row.textContent)) row.querySelector("input").click();
    }
    document.getElementById("group-form").requestSubmit()`);
  await check('document.getElementById("title").textContent === "Browser group" && !document.getElementById("group-compose").hidden');
  await evaluate(`
    const groupTask = document.getElementById("group-task");
    groupTask.focus();
    groupTask.value = "@bro";
    groupTask.setSelectionRange(4, 4);
    groupTask.dispatchEvent(new Event("input"))`);
  await check('document.querySelector("#group-mentions button")?.textContent === "@browser-test"');
  await cdp("Input.dispatchKeyEvent", {type: "keyDown", key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40});
  await cdp("Input.dispatchKeyEvent", {type: "keyUp", key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40});
  await check('document.activeElement === document.querySelector("#group-mentions button")');
  await cdp("Input.dispatchKeyEvent", {type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r"});
  await cdp("Input.dispatchKeyEvent", {type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13});
  await check('groupTask.value === "@browser-test " && document.getElementById("group-routing").textContent === "Sending to: browser-test"');
  await evaluate(`
    groupTask.value += "Browser group task";
    groupTask.dispatchEvent(new Event("input"));
    document.getElementById("group-compose").requestSubmit()`);
  await check('document.querySelector("#group-messages .group-reply")?.textContent.includes("Group answer to @browser-test Browser group task")');
  await check('document.querySelector("#group-messages .receipts li")?.textContent === "browser-test: Sent to agent"');
  await check('app.online && ["claude-capture", "substitute"].every(name => app.agents.some(agent => agent.name === name && live(agent)))');
  await evaluate('document.getElementById("group-edit").click()');
  await check('["claude-capture", "substitute"].every(name => [...document.querySelectorAll("#group-options label")].some(row => row.textContent === name))');
  await evaluate(`
    for (const row of document.querySelectorAll("#group-options label")) {
      if (["claude-capture", "substitute"].includes(row.textContent)) row.querySelector("input").click();
    }
    document.getElementById("group-form").requestSubmit()`);
  try {
    await check('!document.getElementById("group-dialog").open && document.getElementById("headline").textContent === "browser-test · substitute"');
  } catch (error) {
    const context = await evaluate(`({headline:document.getElementById("headline").textContent, error:document.getElementById("group-form-error").textContent,
      choices:[...document.querySelectorAll("#group-options input:checked")].map(field => field.parentElement.textContent)})`);
    throw new Error(error.message + " " + JSON.stringify(context));
  }
  await check('document.querySelector("#group-messages .group-reply")?.textContent.includes("Browser group task")');
  await evaluate(`groupTask.focus(); groupTask.value = "@everyone Please check the status.";
    groupTask.setSelectionRange(groupTask.value.length, groupTask.value.length);
    groupTask.dispatchEvent(new Event("input"))`);
  await check('document.getElementById("group-routing").textContent === "Sending to: browser-test, substitute"');
  await cdp("Emulation.setDeviceMetricsOverride", { width: 375, height: 812, deviceScaleFactor: 1, mobile: true });
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("group-send").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.setDeviceMetricsOverride", { width: 812, height: 375, deviceScaleFactor: 1, mobile: true });
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("group-send").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (screenshot) {
    const { data } = await cdp("Page.captureScreenshot", { format: "png" });
    await writeFile(screenshot.replace(/\.png$/, "-group.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.getElementById("group-compose").requestSubmit()');
  try {
    await waitFor(() => evaluate(`[...document.querySelectorAll("#group-messages .group-reply")]
      .filter(row => row.textContent.includes("Group answer to @everyone Please check the status.")).length === 2`),
    "The two group recipients did not both reply", 250);
  } catch (error) {
    const state = await evaluate(`({error:document.getElementById("group-error").textContent,
      receipts:[...document.querySelectorAll("#group-messages .receipts")].at(-1)?.textContent,
      replies:[...document.querySelectorAll("#group-messages .group-reply > p")].map(el=>el.textContent)})`);
    throw new Error(error.message + " " + JSON.stringify(state));
  }
  await check(`[...document.querySelectorAll("#group-messages article")].some(row =>
    row.querySelector("p")?.textContent === "@everyone Please check the status."
    && Array.from(row.querySelectorAll(".receipts li"), item => item.textContent).join("|")
       === "browser-test: Sent to agent|substitute: Sent to agent")`);
  if (focus === "groups") {
    await evaluate(`const transcriptFixture = new DataTransfer();
      transcriptFixture.items.add(new File(["Synthetic group file bytes"], "transcript sample.txt"));
      const transcriptPicker = document.getElementById("group-file-picker");
      transcriptPicker.files = transcriptFixture.files;
      transcriptPicker.dispatchEvent(new Event("change"));
      groupTask.value = "@browser-test Check live group progress";
      groupTask.dispatchEvent(new Event("input"));
      document.getElementById("group-compose").requestSubmit()`);
    const live = 'document.getElementById("group-live-drafts")';
    await check(live + '.textContent.includes("Checking <em>sample rows</em>.") && !' + live +
      '.querySelector("em") && !document.getElementById("group-messages").textContent.includes("sample rows")');
    assert.equal(await evaluate(live + '.querySelector("strong").textContent'), "browser-test");
    const gate = join(temp, "group-draft-gate");
    const step = async (number) => {
      await writeFile(gate + ".pending", number);
      await rename(gate + ".pending", gate);
    };
    await step("1");
    await check(live + '.textContent.includes("Reviewing the last row.") && !' + live + '.textContent.includes("sample rows")');
    await step("2");
    await check(live + '.hidden && document.getElementById("group-messages").textContent.includes("Group answer to @browser-test Check live group progress") && !document.getElementById("group-messages").textContent.includes("Reviewing the last row.")');
    const transcripts = join(temp, "group-transcripts");
    await cdp("Page.setDownloadBehavior", {behavior:"allow", downloadPath:transcripts});
    await evaluate('document.getElementById("group-transcript").click()');
    const transcript = await waitFor(() => readFile(join(transcripts, "Browser-group.txt"), "utf8").catch(() => ""), "Group transcript download failed");
    assert.match(transcript, /File: transcript sample\.txt/);
    assert.match(transcript, /Group answer to @browser-test Check live group progress/);
    assert.doesNotMatch(transcript, /Reviewing the last row|Synthetic group file bytes/);
    assert.ok(transcript.indexOf("Browser group task") < transcript.indexOf("Check live group progress"));
    const roster = (name) => `[...document.querySelectorAll("#agents .agent")].find(button => button.querySelector("strong")?.textContent === ${JSON.stringify(name)})`;
    const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Browser group"))';
    await check("Boolean(" + roster("substitute") + ")");
    await evaluate(roster("substitute") + `.click();
      const directDraft = document.getElementById("task");
      directDraft.value = "Existing draft note.";
      directDraft.dispatchEvent(new Event("input"));`);
    await evaluate(group + '.click()');
    const groupReply = '[...document.querySelectorAll("#group-messages .group-reply")].find(row => row.textContent.includes("Group answer to @browser-test Check live group progress"))';
    const agentOptions = 'document.getElementById("handoff-agent").options';
    const choose = 'document.getElementById("handoff-agent").value = [...' + agentOptions + '].find(option => option.textContent === "substitute").value';
    await check("Boolean(" + groupReply + '?.querySelector(".handoff-action"))');
    await evaluate(groupReply + '.querySelector(".handoff-action").click()');
    await check('document.getElementById("handoff-dialog").open && document.activeElement.id === "handoff-agent" && ![...' + agentOptions + '].some(option => option.textContent === "browser-test")');
    await evaluate(choose + '; document.getElementById("handoff-instructions").value = "Check the group result."; document.getElementById("handoff-form").requestSubmit()');
    await check('!document.getElementById("handoff-dialog").open && document.getElementById("title").textContent === "substitute" && document.activeElement.id === "task"');
    assert.equal(await evaluate('directDraft.value'), "Existing draft note.\n\nCheck the group result.\n\nContext from browser-test in Browser group:\n> Group answer to @browser-test Check live group progress");
    await evaluate(roster("browser-test") + '.click()');
    await check('Boolean(document.querySelector("#tasks .handoff-action"))');
    await evaluate('document.querySelector("#tasks .handoff-action").click()');
    await check('document.getElementById("handoff-context").textContent.includes("Context from browser-test:")');
    await evaluate('document.getElementById("handoff-cancel").click(); ' + roster("substitute") + '.click()');
    await check('directDraft.value.startsWith("Existing draft note.") && !document.getElementById("tasks").textContent.includes("Check the group result.") && !document.getElementById("output").textContent.includes("Check the group result.")');
    await evaluate(roster("browser-test") + '.click()');
    await check('Boolean(document.querySelector("#tasks .direct-reply"))');
    await evaluate(`document.querySelector("#tasks .direct-reply").click();
      directDraft.value = "Unsent quoted reply";
      directDraft.dispatchEvent(new Event("input"));`);
    await evaluate(group + '.click()');
    await check('[...document.querySelectorAll("#group-recipients label")].some(label => label.textContent.trim() === "substitute")');
    await evaluate(`const checkedRecipient = [...document.querySelectorAll("#group-recipients label")].find(label => label.textContent.trim() === "substitute").querySelector("input");
      if (!checkedRecipient.checked) checkedRecipient.click();
      groupTask.value = "Unsent group draft";
      groupTask.dispatchEvent(new Event("input"));
      const oldGroupFiles = new DataTransfer();
      oldGroupFiles.items.add(new File(["fixture draft bytes"], "draft notes.txt"));
      const groupPicker = document.getElementById("group-file-picker");
      groupPicker.files = oldGroupFiles.files;
      groupPicker.dispatchEvent(new Event("change"));
      window.beforeDraftReload = true;`);
    await check('document.getElementById("group-draft-files").textContent.includes("draft notes.txt")');
    await cdp("Page.reload");
    await check('!window.beforeDraftReload && Boolean(' + roster("substitute") + ') && Boolean(' + group + ')');
    await evaluate(roster("substitute") + '.click()');
    await check('document.getElementById("task").value.includes("Check the group result.") && !document.getElementById("tasks").textContent.includes("Check the group result.")');
    await evaluate(roster("browser-test") + '.click()');
    await check('document.getElementById("task").value === "Unsent quoted reply" && !document.getElementById("direct-reply-target").hidden');
    await evaluate('document.getElementById("direct-cancel-reply").click(); ' + group + '.click()');
    await check('document.getElementById("group-task").value === "Unsent group draft" && document.getElementById("group-routing").textContent === "Sending to: substitute" && !document.getElementById("group-missing-files").hidden && document.getElementById("group-missing-files-label").textContent.includes("draft notes.txt") && document.getElementById("group-send").disabled');
    await evaluate(`const restoredPicker = document.getElementById("group-file-picker");
      const replacementFiles = new DataTransfer();
      replacementFiles.items.add(new File(["test restored bytes"], "draft notes.txt"));
      restoredPicker.files = replacementFiles.files;
      restoredPicker.dispatchEvent(new Event("change"));`);
    await check('document.getElementById("group-missing-files").hidden && !document.getElementById("group-send").disabled && !document.getElementById("group-messages").textContent.includes("Unsent group draft")');
    await evaluate('app.token = "invalid fixture token"; void refresh()');
    await check('document.getElementById("core-status").textContent === "Workspace locked" && !sessionStorage.getItem("swarmhub-tab-drafts-v1")');
  }
}

async function verifyDirectFileGestures() {
  const staged = (name) => `document.getElementById("direct-draft-files").textContent.includes(${JSON.stringify(name)})`;
  const hint = 'document.querySelector("#composer .composer-drop-hint")';
  await check('!document.getElementById("attach").disabled');
  await evaluate(`(() => {
    const composer = document.getElementById("composer");
    window.directDropFiles = new DataTransfer();
    directDropFiles.items.add(new File(["Dropped document"], "drop.txt"));
    composer.dispatchEvent(new DragEvent("dragover", {bubbles:true,cancelable:true,dataTransfer:directDropFiles}));
  })()`);
  await check(`${hint}.getBoundingClientRect().width > 0`);
  await evaluate(`document.getElementById("task").dispatchEvent(new DragEvent("drop",
    {bubbles:true,cancelable:true,dataTransfer:directDropFiles}))`);
  await check(`${hint}.hidden && ${staged("drop.txt")} && !document.getElementById("attach").disabled`);
  assert.equal(await evaluate(`(() => {
    const data = new DataTransfer();
    data.setData("text/plain", "Ordinary text");
    data.items.add(new File(["Ignored image fixture"], "ignored.png", {type:"image/png"}));
    return document.getElementById("task").dispatchEvent(new ClipboardEvent("paste",
      {bubbles:true,cancelable:true,clipboardData:data}));
  })()`), true);
  assert.equal(await evaluate(`(() => {
    const data = new DataTransfer();
    data.items.add(new File(["Screenshot fixture bytes"], "screenshot.png", {type:"image/png"}));
    return document.getElementById("task").dispatchEvent(new ClipboardEvent("paste",
      {bubbles:true,cancelable:true,clipboardData:data}));
  })()`), false);
  await check(staged("screenshot.png") + ' && !document.getElementById("attach").disabled');
  await evaluate(`(() => {
    const data = new DataTransfer();
    for (const name of ["first-rejected.txt", "second-rejected.txt", "third-rejected.txt"]) data.items.add(new File([name], name));
    document.getElementById("task").dispatchEvent(new DragEvent("drop", {bubbles:true,cancelable:true,dataTransfer:data}));
  })()`);
  await check('document.getElementById("composer-error").textContent.includes("up to four files")');
  assert.equal(await evaluate('document.getElementById("tasks").textContent.includes("drop.txt") || ' + staged("rejected.txt")), false);
  await check('Boolean(document.querySelector("#tasks .direct-reply"))');
  await evaluate(`document.querySelector('#direct-draft-files [aria-label="Remove screenshot.png"]').click();
    document.querySelector("#tasks .direct-reply").click();
    document.getElementById("task").value = "Check the direct attachment";
    document.getElementById("task").dispatchEvent(new Event("input"));
    document.getElementById("composer").requestSubmit();`);
  await check('document.getElementById("direct-draft-files").hidden && document.getElementById("tasks").textContent.includes("drop.txt") && document.getElementById("tasks").textContent.includes("Check the direct attachment")');
  assert.equal(await evaluate('document.getElementById("tasks").textContent.includes("screenshot.png")'),false);
  await evaluate('document.querySelector(\'#tasks [aria-label="Preview drop.txt"]\').closest("article").querySelector(".thread-open").click()');
  await check('Boolean(document.querySelector(\'#direct-thread-items [aria-label="Preview drop.txt"]\'))');
  await evaluate('document.querySelector(\'#direct-thread-items [aria-label="Preview drop.txt"]\').click()');
  await check('document.getElementById("sent-file-dialog").open && document.getElementById("file-text").textContent === "Dropped document"');
  await evaluate('document.getElementById("files-back").click()');
  await check('!document.getElementById("sent-file-dialog").open && document.getElementById("direct-thread").open');
  await evaluate('document.getElementById("direct-thread-close").click()');
  await check('[...document.querySelectorAll("#tasks .reply-item")].some(row => row.textContent.includes("drop.txt"))');
}

async function verifyOfflineDirectFile() {
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-conversations").click()');
  const archive = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith("browser-test"))';
  await check(`Boolean(${archive})`);
  await evaluate(`${archive}.click()`);
  const file = `document.querySelector('#archive-items [aria-label="Preview drop.txt"]')`;
  await check(`Boolean(${file})`);
  await evaluate(`${file}.click()`);
  await check('document.getElementById("sent-file-dialog").open && document.getElementById("file-text").textContent === "Dropped document"');
  const folder = join(temp,"direct-downloads");
  await cdp("Page.setDownloadBehavior", {behavior:"allow",downloadPath:folder});
  await evaluate('document.getElementById("file-download").click()');
  assert.equal(await waitFor(() => readFile(join(folder,"drop.txt"),"utf8").catch(() => ""),"Saved direct attachment download failed"),"Dropped document");
  await evaluate('document.getElementById("files-back").click()');
  await check('document.getElementById("library").open && !document.getElementById("archive-view").hidden');
}

async function verifyGroupFiles() {
  await check('!document.getElementById("group-attach").disabled');
  await evaluate(`(() => {
    const files = new DataTransfer();
    files.items.add(new File(["Group report contents"], "group report.txt"));
    files.items.add(new File(["Do not share"], "remove.txt"));
    groupTask.dispatchEvent(new DragEvent("drop", {bubbles:true,cancelable:true,dataTransfer:files}));
    const clipboard = new DataTransfer();
    clipboard.items.add(new File(["Screenshot fixture bytes"], "group screenshot.png", {type:"image/png"}));
    groupTask.dispatchEvent(new ClipboardEvent("paste", {bubbles:true,cancelable:true,clipboardData:clipboard}));
  })()`);
  await check('document.querySelectorAll("#group-draft-files li").length === 3');
  await evaluate(`for (const name of ["remove.txt", "group screenshot.png"]) {
      document.querySelector('#group-draft-files [aria-label="Remove ' + name + '"]').click();
    }
    groupTask.value = "@browser-test Check the document";
    groupTask.dispatchEvent(new Event("input"));
    [...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("browser-test")).click();
    [...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Browser group")).click()`);
  await check('document.querySelectorAll("#group-draft-files li").length === 1 && document.getElementById("group-draft-files").textContent.includes("group report.txt")');
  await check('!document.querySelector("#group-messages .group-files") && !document.getElementById("group-send").disabled');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("group-send").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await evaluate('document.getElementById("group-compose").requestSubmit()');
  await check('document.querySelector("#group-messages .group-files button")?.textContent === "Download group report.txt" && document.getElementById("group-draft-files").hidden');
  await check('[...document.querySelectorAll("#group-messages .group-reply")].some(row => row.textContent.includes("Group answer to @browser-test Check the document"))');
  const path = join(temp, "group-downloads");
  await cdp("Page.setDownloadBehavior", {behavior: "allow", downloadPath: path});
  await evaluate('document.querySelector("#group-messages .group-files button").click()');
  assert.equal(await waitFor(() => readFile(join(path, "group report.txt"), "utf8").catch(() => ""), "Group attachment download failed"),
    "Group report contents");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-group-files.png"), Buffer.from(data, "base64"));
  }
}

async function verifyGroupResults() {
  await evaluate(`groupTask.value = "@browser-test Return a downloadable report";
    groupTask.dispatchEvent(new Event("input"));
    document.getElementById("group-compose").requestSubmit()`);
  const result = '[...document.querySelectorAll("#group-messages .group-reply")].find(row => row.textContent.includes("Return a downloadable report"))';
  await check(`${result}?.querySelector(".group-files button")?.textContent === "Download Agent report.txt"`);
  const path = join(temp, "result-downloads");
  await cdp("Page.setDownloadBehavior", {behavior: "allow", downloadPath: path});
  await evaluate(`${result}.querySelector(".group-files button").click()`);
  assert.equal(await waitFor(() => readFile(join(path, "Agent report.txt"), "utf8").catch(() => ""), "Group result download failed"),
    "Agent report contents");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    await evaluate(`${result}.scrollIntoView({block:"end"})`);
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-group-results.png"), Buffer.from(data, "base64"));
  }
}

async function verifyGroupQuestions() {
  await evaluate(`groupTask.value = "@browser-test Ask a group question";
    groupTask.dispatchEvent(new Event("input"));
    document.getElementById("group-compose").requestSubmit()`);
  const question = '[...document.querySelectorAll("#group-messages article")].find(row => row.querySelector(".group-answer-state"))';
  await check(`${question}?.querySelector(".group-direct-reply")?.textContent === "Answer"`);
  await check('document.getElementById("attention-count").textContent === "1"');
  await evaluate('document.getElementById("attention-open").click()');
  await check('document.querySelector("#attention-list button")?.textContent.includes("Which report section should I use?")');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const { data } = await cdp("Page.captureScreenshot", { format: "png" });
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-attention.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.querySelector("#attention-list button").click()');
  await check('document.getElementById("group-reply-name").textContent === "Answering browser-test" && document.getElementById("group-recipient-field").hidden');
  await evaluate(`groupTask.value = "@everyone Use the summary.";
    groupTask.dispatchEvent(new Event("input"))`);
  await check('document.getElementById("group-routing").textContent === "Sending to: browser-test" && document.getElementById("group-send").textContent === "Send answer"');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("group-send").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await evaluate('document.getElementById("group-compose").requestSubmit()');
  const answer = '[...document.querySelectorAll("#group-messages article")].find(row => row.querySelector("blockquote"))';
  await check(`${answer}?.querySelector("blockquote")?.textContent.includes("Which report section should I use?")`);
  await check(`${answer}?.querySelectorAll(".receipts li").length === 1 && ${question}?.querySelector(".group-answer-state")?.textContent === "Answer sent"`);
  await check('[...document.querySelectorAll("#group-messages .group-reply")].some(row => row.textContent.includes("Group answer to @everyone Use the summary."))');
  await check('document.getElementById("attention-count").hidden');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    await evaluate(`${answer}.scrollIntoView({block:"end"})`);
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-group-questions.png"), Buffer.from(data, "base64"));
  }
}

async function verifyGitHubProject() {
  const issue = '[...document.querySelectorAll("#github-project-items button")].find(button => button.textContent.startsWith("Issue #5:"))';
  const pull = '[...document.querySelectorAll("#github-project-items button")].find(button => button.textContent.startsWith("Pull request #12:"))';
  const attach = 'document.getElementById("github-project-attach")';
  await check('document.getElementById("core-status")?.textContent === "Herdr Core connected" && !document.getElementById("github-project-open").disabled');
  await evaluate('document.getElementById("workspace-tools").open = true; document.getElementById("github-project-open").click()');
  await check('Boolean(' + issue + ') && Boolean(' + pull + ')');
  await evaluate('document.getElementById("github-project-more").click()');
  await check('document.getElementById("github-project-items").textContent.includes("Another open issue")');
  await evaluate(issue + '.click()');
  await check('document.getElementById("github-project-excerpt").textContent.includes("<script>window.projectInjected=true</script>") && ' + attach + '.hidden');
  assert.equal(await evaluate('typeof window.projectInjected'), "undefined");
  assert.equal(await evaluate('document.getElementById("github-project-excerpt").childElementCount'), 0);
  await evaluate('document.getElementById("github-project-close").click()');

  const agent = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "github-browser")';
  await check('Boolean(' + agent + ')');
  await evaluate(agent + '.click()');
  await check('document.getElementById("title").textContent === "github-browser" && !document.getElementById("github-project-direct").disabled && !document.getElementById("github-project-direct").hidden');
  await evaluate('document.getElementById("github-project-direct").click()');
  await check('Boolean(' + pull + ')');
  await evaluate(pull + '.click()');
  await check('document.getElementById("github-project-excerpt").textContent === "Review the café notes. <img src=x onerror=alert(1)>" && !' + attach + '.hidden && !' + attach + '.disabled');
  await evaluate(attach + '.click()');
  await check('!document.getElementById("github-project-dialog").open && document.getElementById("direct-draft-files").textContent.includes("github-pulls-12.txt")');
  assert.equal(await evaluate('document.getElementById("tasks").textContent.includes("Review the attached GitHub excerpt.")'), false);
  await evaluate(`const projectTask = document.getElementById("task");
    projectTask.value = "Review the attached GitHub excerpt.";
    projectTask.dispatchEvent(new Event("input"));
    document.getElementById("composer").requestSubmit()`);
  await check('document.getElementById("tasks").textContent.includes("Review the attached GitHub excerpt.") && document.getElementById("tasks").textContent.includes("github-pulls-12.txt")');

  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("GitHub review group"))';
  await check('Boolean(' + group + ')');
  await evaluate(group + '.click()');
  await check('!document.getElementById("github-project-group").hidden && !document.getElementById("github-project-group").disabled');
  await evaluate('document.getElementById("github-project-group").click()');
  await check('Boolean(' + issue + ')');
  await evaluate(issue + '.click()');
  await check('!' + attach + '.hidden && !' + attach + '.disabled');
  await evaluate(attach + '.click()');
  await check('!document.getElementById("github-project-dialog").open && document.getElementById("group-draft-files").textContent.includes("github-issues-5.txt")');
  assert.equal(await evaluate('document.querySelectorAll("#group-messages article").length'), 0);
}

async function verifyGroupHandoffs() {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core connected"');
  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Handoff team"))';
  await check('Boolean(' + group + ')');
  await evaluate(group + '.click()');
  await check('document.querySelectorAll("#group-messages [data-group-handoff]").length === 2');
  const card = (index) => 'document.querySelectorAll("#group-messages [data-group-handoff]")[' + index + ']';
  assert.equal(await evaluate('document.querySelectorAll("#group-messages article").length'), 4);
  await evaluate(card(0) + '.click()');
  await check('document.getElementById("group-handoff-recipient").value === "handoff-editor" && document.getElementById("group-handoff-recipient").readOnly && document.getElementById("group-handoff-task").value === "Review the release draft." && document.getElementById("group-handoff-excerpt").textContent === "Gather the release requirements."');
  assert.equal(await evaluate('document.querySelectorAll("#group-messages article").length'), 4);
  await evaluate('document.getElementById("group-handoff-cancel").click()');
  await check('!document.getElementById("group-handoff-dialog").open && ' + card(0) + '.textContent === "Review handoff"');
  await evaluate(card(0) + '.click()');
  await check('!document.getElementById("group-handoff-send").disabled && document.getElementById("group-handoff-task").value === "Review the release draft."');
  await evaluate(`document.getElementById("group-handoff-task").value = "Review the release draft and flag the date.";
    document.getElementById("group-handoff-form").requestSubmit()`);
  await check('document.getElementById("group-handoff-status").textContent.includes("Handoff queued") && ' + card(0) + '.textContent === "Handoff approved"');
  await evaluate('document.getElementById("group-handoff-close").click()');
  await check('document.querySelectorAll("#group-messages article").length === 5 && document.getElementById("group-messages").textContent.includes("Review the release draft and flag the date.")');
  await evaluate(card(1) + '.click()');
  await check('document.getElementById("group-handoff-task").value === "This suggestion should be dismissed."');
  await evaluate('document.getElementById("group-handoff-dismiss").click()');
  await check('document.getElementById("group-handoff-status").textContent === "Handoff dismissed." && ' + card(1) + '.disabled');
}

async function verifyGroupForms() {
  await evaluate(`groupTask.value = "@browser-test Ask for a group form";
    groupTask.dispatchEvent(new Event("input"));
    document.getElementById("group-compose").requestSubmit()`);
  const form = '[...document.querySelectorAll("#group-messages article")].find(row => row.querySelector(".group-direct-reply")?.textContent === "Fill out form")';
  await check(`!!${form}`);
  await check('document.getElementById("attention-count").textContent === "1"');
  await evaluate('document.getElementById("attention-open").click()');
  await check('document.querySelector("#attention-list button")?.textContent.includes("Review preferences")');
  await evaluate('document.querySelector("#attention-list button").click()');
  await check('document.getElementById("group-input-dialog").open && document.getElementById("group-input-recipient").textContent.includes("browser-test")');
  await check('document.querySelector("#group-input-fields label[for=group-answer-field-1]").textContent === "Notes <draft> (optional)" && !document.querySelector("#group-input-fields draft")');
  await evaluate('document.getElementById("group-input-form").requestSubmit()');
  await check('document.getElementById("group-input-dialog").open && !document.getElementById("group-answer-field-0").validity.valid');
  await evaluate(`document.getElementById("group-answer-field-0").value = "Timeline";
    document.getElementById("group-answer-field-1").value = "Focus on verified dates.";`);
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("group-input-submit").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-group-forms.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.getElementById("group-input-form").requestSubmit()');
  const response = 'document.querySelector(".group-form-values")';
  await check(`${response}?.textContent.includes("Timeline") && ${response}?.textContent.includes("Focus on verified dates.")`);
  await check(`${response}.closest("article").querySelectorAll(".receipts li").length === 1 && !document.getElementById("group-input-dialog").open`);
  await check('document.getElementById("attention-count").hidden');
}

async function verifyChecklist() {
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-pages").click()');
  const open = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.includes("Launch checklist"))';
  await check('Boolean(' + open + ')');
  await evaluate(open + '.click()');
  const boxes = 'document.querySelectorAll("#page-markdown-preview input[type=checkbox]")';
  await check(boxes + '.length === 2 && !' + boxes + '[0].disabled && !' + boxes + '[1].checked && document.getElementById("page-notice").textContent.includes("Revision 2")');
  await check(boxes + '[0].getAttribute("aria-label") === "Prepare café notes"');
  await evaluate(boxes + '[0].click()');
  await check(boxes + '[0]?.checked && document.activeElement === ' + boxes + '[0] && document.getElementById("page-notice").textContent.includes("Revision 3")');
  await evaluate(`window.updatedChecklist = false;
    void api("/api/pages").then(items => api("/api/pages/" + items.find(item => item.title === "Launch checklist").id))
      .then(page => api("/api/pages/" + page.id, {title:page.title,revision:page.revision,markdown:"- [ ] Added elsewhere\\n\\n" + page.markdown}))
      .then(() => { window.updatedChecklist = true; });`);
  await check('window.updatedChecklist');
  await evaluate(boxes + '[1].click()');
  await check('!document.getElementById("page-reload").hidden && ' + boxes + '[1].disabled && !' + boxes + '[1].checked');
  await evaluate('document.getElementById("page-reload").click()');
  await check(boxes + '.length === 3 && ' + boxes + '[0].getAttribute("aria-label") === "Added elsewhere" && !' + boxes + '[0].disabled');
  await evaluate(boxes + '[0].click()');
  await check(boxes + '[0].checked && ' + boxes + '[1].checked && !' + boxes + '[2].checked && document.getElementById("page-notice").textContent.includes("Revision 5")');
  await evaluate('document.querySelector("#page-revisions summary").click()');
  const revision = '[...document.querySelectorAll("#page-revision-list button")].find(button => button.textContent.startsWith("Revision 2"))';
  await check('Boolean(' + revision + ')');
  await evaluate(revision + '.click()');
  await check(boxes + '.length === 2 && ' + boxes + '[0].disabled && document.getElementById("page-edit").hidden && !document.getElementById("page-restore").disabled && document.getElementById("page-notice").textContent.includes("Read-only revision")');
  await evaluate('document.getElementById("page-restore").click()');
  await check('document.getElementById("page-notice").textContent === "Revision 2 restored as revision 6." && !' + boxes + '[0].disabled && !' + boxes + '[0].checked');
  await check('document.querySelector("#page-revision-list button")?.textContent.includes("Revision 6 · Latest") && document.querySelector("#page-revision-list").textContent.includes("Revision 5")');
}

async function verifyPageTables() {
  await evaluate('document.getElementById("page-close").click(); document.getElementById("library-open").click(); document.getElementById("library-pages").click()');
  const tracker = '[...document.querySelectorAll("#library-items li > button:first-child")].find(button => button.textContent.startsWith("Launch tracker"))';
  await check(`Boolean(${tracker})`);
  await evaluate(`${tracker}.click()`);
  await check('document.querySelectorAll(".page-table-controls").length === 2');
  await evaluate('document.querySelector(".page-table-controls summary").click()');
  const select = (index,value,type="change") => `(() => {
    const field = document.getElementById("page-table-0-${index}");
    field.value = ${JSON.stringify(value)};
    field.dispatchEvent(new Event(${JSON.stringify(type)}));
  })()`;
  const visible = '[...document.querySelector(".page-table-scroll").querySelectorAll("tbody tr:not([hidden])")].map(row => row.cells[0].textContent)';
  await evaluate(select(0,"cafe done","input"));
  assert.deepEqual(await evaluate(visible),["Café follow-up"]);
  await evaluate(select(1,"1") + ";" + select(0,"OPEN","input"));
  assert.deepEqual(await evaluate(visible),["Queue migration"]);
  await evaluate(select(0,"nobody","input"));
  await check('document.querySelector(".page-table-controls [role=status]").textContent.includes("No rows match") && document.querySelectorAll(".page-table-scroll")[1].querySelectorAll("tr[hidden]").length === 0');
  await evaluate('document.querySelector(".page-table-controls button").click(); ' + select(2,"2"));
  assert.deepEqual(await evaluate(visible),["Café follow-up","Prepare open agenda","Queue migration"]);
  await evaluate(select(3,"desc"));
  assert.deepEqual(await evaluate(visible),["Queue migration","Prepare open agenda","Café follow-up"]);
  await check('document.querySelector(".page-table-scroll th[aria-sort=descending]").textContent === "Estimate" && document.getElementById("page-notice").textContent.startsWith("Revision 1")');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("page-table-0-0").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await evaluate('document.querySelector(".page-table-controls button").click()');
  assert.deepEqual(await evaluate(visible),["Queue migration","Café follow-up","Prepare open agenda"]);

  const charts = 'document.querySelectorAll(".page-chart")';
  await check(`${charts}.length === 2 && ${charts}[0].querySelector("figcaption").textContent.startsWith("Weekly <em>changes</em>") && !${charts}[0].querySelector("em")`);
  assert.deepEqual(await evaluate(`[...${charts}[0].querySelectorAll(".page-chart-bar")].map(bar => [bar.style.insetInlineStart,bar.style.width])`),
    [["0%","40%"],["40%","60%"]]);
  await check(`${charts}[1].querySelectorAll("svg circle").length === 3 && ${charts}[1].querySelector("polyline").getAttribute("points").split(" ").length === 3`);
  await evaluate(`${charts}[1].querySelector("summary").click()`);
  assert.deepEqual(await evaluate(`[...${charts}[1].querySelectorAll("details[open] tbody td")].map(cell => cell.textContent)`), ["-2.5","0","3"]);
  await check('document.querySelector("#page-markdown-preview code.language-chart")?.textContent.includes("<script>literal text</script>") && !document.querySelector("#page-markdown-preview script")');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check(`${charts}[1].querySelector("svg").getBoundingClientRect().right <= innerWidth && document.documentElement.scrollWidth <= innerWidth`);
  await cdp("Emulation.clearDeviceMetricsOverride");
}

async function verifyChatLinks() {
  const roster = (name) => `[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === ${JSON.stringify(name)})`;
  const text = "Review & compare café options.\nKeep <draft> as text.";
  await check('Boolean(' + roster("chat-link-live") + ') && Boolean(' + roster("chat-link-idle") + ')');
  await evaluate(roster("chat-link-live") + `.click(); document.getElementById("details-toggle").click();
    document.getElementById("agent-chat-link").click(); document.getElementById("agent-chat-link-draft").value = ${JSON.stringify(text)};
    document.getElementById("agent-chat-link-draft").dispatchEvent(new Event("input"))`);
  const url = new URL(await evaluate('document.getElementById("agent-chat-link-value").value'));
  const link = new URLSearchParams(url.hash.slice(1));
  assert.equal(link.get("draft"),text);
  assert.equal(url.search, "");
  assert.ok(!url.href.includes(token));
  await evaluate(`sessionStorage.removeItem("swarmhub-token"); history.replaceState(null,"",${JSON.stringify(url.href)})`);
  await cdp("Page.reload");
  await check('document.getElementById("core-status")?.textContent === "Workspace locked" && !document.getElementById("task").value');
  assert.equal(await evaluate("location.hash"), url.hash);
  await evaluate(`document.getElementById("unlock").click(); document.getElementById("token").value = ${JSON.stringify(token)};
    document.getElementById("access-form").requestSubmit()`);
  await check('document.getElementById("title").textContent === "chat-link-live" && document.getElementById("task").value === ' + JSON.stringify(text));
  assert.equal(await evaluate("location.hash"), '#agent=' + link.get("agent"));
  assert.equal(await evaluate('document.getElementById("tasks").textContent.includes("compare café") || document.getElementById("output").textContent.includes("compare café")'), false);
  await evaluate(`location.hash = ${JSON.stringify('#agent=' + link.get("agent") + "&draft=Do+not+overwrite")}`);
  await check('document.getElementById("notice").textContent.includes("linked draft was skipped")');
  assert.equal(await evaluate('document.getElementById("task").value'),text);
  await evaluate(`location.hash = "agent=" + app.profiles.find(profile => profile.name === "chat-link-idle").id + "&draft=Draft+for+the+next+session"`);
  await check('document.getElementById("title").textContent === "chat-link-idle" && document.getElementById("notice").textContent.includes("linked draft will be ready") && !document.getElementById("launch").open');
  await evaluate('document.getElementById("profile-start").click()');
  await check('document.getElementById("launch").open && document.getElementById("first-task").value === "Draft for the next session"');
  await evaluate('document.getElementById("cancel-launch").click(); document.getElementById("new").click()');
  await check('document.getElementById("launch").open && !document.getElementById("first-task").value');
  await evaluate('document.getElementById("cancel-launch").click(); document.getElementById("profile-start").click()');
  await check('document.getElementById("first-task").value === "Draft for the next session"');
}

async function verifyAgentLibrary() {
  const roster = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "library-agent")';
  await check('Boolean(' + roster + ')');
  await evaluate(roster + '.click(); document.getElementById("details-toggle").click(); document.getElementById("agent-library").click()');
  const items = 'document.getElementById("library-items")';
  await check('document.getElementById("library-heading").textContent === "library-agent · Library" && ' + items + '.querySelectorAll("li").length === 4');
  const item = (name) => `[...${items}.querySelectorAll("button")].find(button => button.textContent.startsWith(${JSON.stringify(name)}))`;
  const first = `${items}.querySelector("li > button")`;
  await evaluate('document.querySelector(\'#library-items [aria-label="Pin Agent comparison"]\').click()');
  await check(first + '?.textContent.includes("Agent comparisonPinned") && document.activeElement.getAttribute("aria-label") === "Unpin Agent comparison"');
  await evaluate(item("First session report.txt") + '.click()');
  await check('document.getElementById("file-text").textContent === "Saved bytes from the first session."');
  await evaluate('document.getElementById("files-back").click()');
  await check('document.getElementById("library-results").getAttribute("aria-pressed") === "true" && ' + items + '.querySelectorAll("li").length === 4');
  await evaluate('document.getElementById("library-pages").click()');
  await check(items + '.querySelectorAll("li").length === 1 && !!' + item("Agent comparison") + ' && document.getElementById("page-new").hidden');
  await evaluate(item("Agent comparison") + '.click()');
  await check('document.getElementById("page-heading").textContent === "Agent comparison"');
  await evaluate('document.getElementById("page-close").click()');
  await check('!document.getElementById("page-dialog").open && document.getElementById("library").open');
  await evaluate('document.getElementById("library-all-agents").click(); document.getElementById("library-pages").click()');
  await check(items + '.querySelectorAll("li").length === 2 && !!' + item("Standalone Page") + ' && !document.getElementById("page-new").hidden');
  assert.match(await evaluate(first + '.textContent'), /^Agent comparisonPinned/);
  await cdp("Page.reload");
  await check('!document.getElementById("library-open").disabled');
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-pages").click()');
  await check('Boolean(document.querySelector(\'#library-items [aria-label="Unpin Agent comparison"]\'))');
  await evaluate('document.querySelector(\'#library-items [aria-label="Unpin Agent comparison"]\').click()');
  await check(first + '?.textContent.startsWith("Standalone Page") && document.activeElement.getAttribute("aria-label") === "Pin Agent comparison"');
}

async function verifyPageHtmlExport() {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-pages").click()');
  const latest = '[...document.querySelectorAll("#library-items li > button")].find(button => button.textContent.startsWith("Current report"))';
  await check('Boolean(' + latest + ')');
  await evaluate(latest + '.click()');
  await check('document.getElementById("page-heading").textContent === "Current report" && document.getElementById("page-notice").textContent.startsWith("Revision 2")');
  await evaluate('document.getElementById("page-revisions").open = true');
  const old = '[...document.querySelectorAll("#page-revision-list button")].find(button => button.textContent.startsWith("Revision 1"))';
  await check('Boolean(' + old + ')');
  await evaluate(old + '.click()');
  await check('document.getElementById("page-heading").textContent === "Quarterly <notes>" && document.getElementById("page-notice").textContent.includes("Read-only revision")');
  const folder = join(temp, "portable-page");
  const file = join(folder, "Quarterly _notes_.html");
  await cdp("Page.setDownloadBehavior", {behavior:"allow", downloadPath:folder});
  await evaluate('document.getElementById("page-download-html").click()');
  const html = await waitFor(() => readFile(file, "utf8").catch(() => ""), "Read-only Page download did not finish");
  await check('document.getElementById("page-export-status").textContent.includes("Downloaded revision 1")');
  assert.ok(!html.includes(token));
  await evaluate('sessionStorage.removeItem("swarmhub-token")');
  await cdp("Network.enable");
  await cdp("Network.setBlockedURLs", {urls:["http://*", "https://*"]});
  const local = pathToFileURL(file).href;
  await cdp("Page.navigate", {url:local});
  await check('location.protocol === "file:" && document.title === "Quarterly <notes>"');
  assert.equal(await evaluate("location.href"), local);
  await check('document.querySelector("header p").textContent.includes("Revision 1") && !document.body.textContent.includes("NEWER REPORT MUST NOT EXPORT")');
  assert.deepEqual(await evaluate('[...document.querySelectorAll("article input")].map(box => [box.checked, box.disabled])'),[[true,true],[false,true]]);
  await check('document.querySelector("article table tbody").textContent.includes("Café") && document.querySelector("figure caption").textContent === "Release <data>"');
  assert.deepEqual(await evaluate('[...document.querySelectorAll("figure tbody td")].map(cell => cell.textContent)'), ["Earlier","0.12345678901234567890","Later <value>","3.50"]);
  await check('document.querySelector("code.language-chart").textContent.includes("null") && document.body.textContent.includes("https://example.invalid/docs")');
  assert.equal(await evaluate('document.querySelectorAll("script,img,iframe,link,a").length'), 0);
  assert.equal(await evaluate('typeof window.exportExecuted'), "undefined");
  assert.equal(await evaluate('performance.getEntriesByType("resource").length'), 0);
}

async function verifyPageLinks() {
  const hash = await evaluate("location.hash");
  assert.match(hash, /^#page=\d+$/);
  await evaluate("history.back()");
  await check('!location.hash && !document.getElementById("page-dialog").open');
  await evaluate("history.forward()");
  await check('document.getElementById("page-dialog").open && document.getElementById("page-notice").textContent.startsWith("Revision 6")');
  const exact = `${hash}&revision=2`;
  await evaluate(`location.hash = ${JSON.stringify(exact)}`);
  await check('document.getElementById("page-notice").textContent.includes("Read-only revision")');
  await evaluate(`Object.defineProperty(navigator, "clipboard", {value:{writeText:() => Promise.reject(new Error("Clipboard blocked"))}});
    document.getElementById("page-copy-link").click()`);
  await check('!document.getElementById("page-link-fallback").hidden && document.activeElement.id === "page-link-value"');
  assert.equal(await evaluate('document.getElementById("page-link-value").value'), `${origin}/${exact}`);
  await evaluate('sessionStorage.removeItem("swarmhub-token")');
  await cdp("Page.reload");
  await check('document.getElementById("core-status")?.textContent === "Workspace locked" && !document.getElementById("page-dialog").open');
  assert.equal(await evaluate("location.hash"), exact);
  await evaluate(`document.getElementById("unlock").click(); document.getElementById("token").value = ${JSON.stringify(token)};
    document.getElementById("access-form").requestSubmit()`);
  await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && document.getElementById("page-dialog").open && document.getElementById("page-notice").textContent.startsWith("Revision 2")');
  await evaluate(`location.hash = ${JSON.stringify(hash + "&revision=200")}`);
  await check('!document.getElementById("page-open-latest").hidden && document.getElementById("page-notice").textContent.includes("no longer available")');
  await evaluate('document.getElementById("page-open-latest").click()');
  await check('document.getElementById("page-notice").textContent.startsWith("Revision 6")');
  assert.equal(await evaluate("location.hash"), hash);
}

async function verifyPages() {
  await evaluate('[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("page-agent")).click()');
  await check('[...document.querySelectorAll("#tasks button")].some(button => button.textContent === "Open page")');
  await evaluate('[...document.querySelectorAll("#tasks button")].find(button => button.textContent === "Open page").click()');
  await check('document.getElementById("page-heading").textContent === "Revised comparison" && document.getElementById("page-markdown-preview").textContent.includes("Latest agent report")');
  if (focus === "page-tasks") await verifyPageDiscussion();
  await evaluate('document.getElementById("page-close").click(); [...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("browser-test")).click()');
  await check('[...document.querySelectorAll("#tasks button")].some(button => button.textContent === "Save as page")');
  await evaluate('[...document.querySelectorAll("#tasks button")].find(button => button.textContent === "Save as page").click()');
  await check('document.getElementById("page-markdown").value.includes("<em>literal text</em>")');
  const markdown = "# Project comparison\n\n| Option | Status |\n| - | - |\n| A | Ready |\n\n<img src=x onerror=alert(1)>";
  await evaluate(`document.getElementById("page-title").value = "Browser comparison";
    document.getElementById("page-markdown").value = ${JSON.stringify(markdown)};
    document.getElementById("page-form").requestSubmit()`);
  await check('document.querySelector("#page-markdown-preview table td")?.textContent === "A" && !document.querySelector("#page-markdown-preview img")');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("page-download").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-pages.png"), Buffer.from(data, "base64"));
  }
  await evaluate(`document.getElementById("page-edit").click(); document.getElementById("page-markdown").value += "\\n\\nA follow-up note.";
    document.getElementById("page-form").requestSubmit()`);
  await check('document.getElementById("page-notice").textContent.startsWith("Revision 2")');
  await evaluate('document.getElementById("page-close").click(); document.getElementById("library-open").click(); document.getElementById("library-pages").click()');
  await check('[...document.querySelectorAll("#library-items button")].some(button => button.textContent.startsWith("Browser comparison"))');
  await evaluate('[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith("Browser comparison")).click()');
  await check('!document.getElementById("page-read").hidden && document.getElementById("page-heading").textContent === "Browser comparison" && document.getElementById("page-markdown-preview").textContent.includes("A follow-up note.")');
  const folder = join(temp, "page-downloads");
  await cdp("Page.setDownloadBehavior", {behavior:"allow",downloadPath:folder});
  await evaluate('document.getElementById("page-download").click()');
  assert.equal(await waitFor(() => readFile(join(folder, "Browser comparison.md"), "utf8").catch(() => ""), "Page download failed"),
    markdown + "\n\nA follow-up note.");
}

async function verifyPageDiscussion() {
  await evaluate('document.getElementById("page-discuss").click()');
  await check('document.getElementById("page-discussion-status").textContent.includes("page-agent about revision 4") && document.getElementById("page-tasks").textContent.includes("Clarify the deadline")');
  await evaluate(`const note = document.getElementById("page-task-text");
    note.value = "Add one line of context.";
    note.dispatchEvent(new Event("input"));
    void api("/api/pages").then(pages => pages.find(page => page.title === "Revised comparison"))
      .then(page => api("/api/pages/" + page.id))
      .then(page => api("/api/pages/" + page.id, {title:page.title, revision:page.revision, markdown:page.markdown + "\\n\\nA teammate edit."}))`);
  await check('!document.getElementById("page-reload").hidden && document.getElementById("page-task-send").disabled');
  await evaluate('document.getElementById("page-reload").click()');
  await check('document.getElementById("page-discussion-status").textContent.includes("revision 5") && document.getElementById("page-task-text").value === "Add one line of context." && !document.getElementById("page-task-send").disabled');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("page-task-send").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-page-tasks.png"), Buffer.from(data, "base64"));
  }
  await evaluate('document.getElementById("page-task-form").requestSubmit()');
  await check('document.getElementById("page-tasks").textContent.includes("Revision 5 · Sent to agent") && document.getElementById("page-tasks").textContent.includes("Add one line of context.")');
  await check('!document.getElementById("page-reload").hidden');
  await evaluate('document.getElementById("page-reload").click()');
  await check('document.getElementById("page-notice").textContent.startsWith("Revision 6") && document.getElementById("page-markdown-preview").textContent.includes("Amended: Add one line of context.")');
  await evaluate('document.getElementById("page-close").click()');
  const older = '[...document.querySelectorAll("#tasks button")].find(button => button.textContent.startsWith("Page: ") && button.textContent.endsWith("revision 5"))';
  await check('Boolean(' + older + ')');
  await evaluate(older + '.click()');
  await check('document.getElementById("page-notice").textContent.startsWith("Revision 5") && document.getElementById("page-notice").textContent.includes("Read-only revision") && !document.getElementById("page-markdown-preview").textContent.includes("Amended: Add one line of context.")');
}

async function verifySearch(offline) {
  await cdp("Input.dispatchKeyEvent", {type:"keyDown", key:"k", code:"KeyK", windowsVirtualKeyCode:75, modifiers:2});
  await cdp("Input.dispatchKeyEvent", {type:"keyUp", key:"k", code:"KeyK", windowsVirtualKeyCode:75, modifiers:2});
  await check('document.getElementById("workspace-search").open && document.activeElement.id === "workspace-query"');
  const enter = async (text, category = "") => {
    await evaluate(`document.getElementById("workspace-query-kind").value = ${JSON.stringify(category)};
      document.getElementById("workspace-query").value = ${JSON.stringify(text)};
      document.getElementById("workspace-query").dispatchEvent(new Event("input"))`);
  };
  const button = 'document.querySelector("#workspace-search-results button")';
  await enter("search");
  await check('[...document.querySelectorAll("#workspace-search-results small")].some(node => node.textContent === "Page")');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("workspace-query-kind").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (!offline && process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-search.png"), Buffer.from(data,"base64"));
  }
  await enter("rare comparison", "pages");
  await check(`${button}?.textContent.includes("Rare comparison marker") && document.querySelectorAll("#workspace-search-results button").length === 1`);
  await cdp("Input.dispatchKeyEvent", {type:"keyDown", key:"ArrowDown", code:"ArrowDown", windowsVirtualKeyCode:40});
  await cdp("Input.dispatchKeyEvent", {type:"keyUp", key:"ArrowDown", code:"ArrowDown", windowsVirtualKeyCode:40});
  await check(`document.activeElement === ${button}`);
  await cdp("Input.dispatchKeyEvent", {type:"keyDown", key:"Enter", code:"Enter", windowsVirtualKeyCode:13, text:"\r"});
  await cdp("Input.dispatchKeyEvent", {type:"keyUp", key:"Enter", code:"Enter", windowsVirtualKeyCode:13});
  await check('document.getElementById("page-heading").textContent === "Search comparison" && document.getElementById("page-markdown-preview").textContent.includes("Rare comparison marker")');
  await evaluate('document.getElementById("page-close").click(); document.getElementById("workspace-search-open").click()');
  await enter("older archive marker", "messages");
  await check(`${button}?.textContent.includes("Older archive marker")`);
  await evaluate(`${button}.click()`);
  await check('document.querySelector("#archive-items .archive-match")?.textContent.includes("Older archive marker") && !document.getElementById("archive-items").textContent.includes("Later message 39")');
  await evaluate('document.getElementById("archive-latest").click()');
  await check('document.getElementById("archive-items").textContent.includes("Later message 39")');
  await evaluate('document.getElementById("library-close").click(); document.getElementById("workspace-search-open").click()');
  await enter("Group search file", "files");
  await check(`${button}?.textContent.includes("Group file · Download")`);
  const folder = join(temp,offline ? "search-offline-downloads" : "search-downloads");
  await cdp("Page.setDownloadBehavior", {behavior:"allow",downloadPath:folder});
  await evaluate(`${button}.click()`);
  assert.equal(await waitFor(() => readFile(join(folder,"Group search file.txt"),"utf8").catch(() => ""),"Search result download failed"),
    "Saved group search file");
  await enter("Search group", "groups");
  await check(`${button}?.textContent.includes("Search group")`);
  await evaluate(`${button}.click()`);
  await check('document.getElementById("title").textContent === "Search group" && document.getElementById("group-messages").textContent.includes("Saved input")');
  const visit = async (text, category, label) => {
    await evaluate('document.getElementById("workspace-search-open").click()');
    await enter(text, category);
    await check(`${button}?.querySelector("small")?.textContent === ${JSON.stringify(label)}`);
    await evaluate(`${button}.click()`);
  };
  await visit("Quartz group marker", "messages", "Group message");
  await check('document.querySelector("#group-messages .archive-match")?.textContent.includes("Quartz group marker") && !document.getElementById("group-messages").textContent.includes("Later group 39")');
  await evaluate('document.getElementById("group-latest").click()');
  await check('document.getElementById("group-messages").textContent.includes("Later group 39")');
  await visit("cobalt review marker", "skills", "Skill");
  await check('document.getElementById("skill-heading").textContent === "Search checklist" && document.getElementById("skill-instructions").textContent === "The cobalt review marker"');
  await evaluate('document.getElementById("skill-close").click()');
  await visit("calendar comparison marker", "routines", "Routine");
  await check('document.getElementById("routine-heading").textContent === "Search check-in" && document.getElementById("routine-instructions").textContent === "The calendar comparison marker"');
  await evaluate('document.getElementById("routine-close").click()');
  await visit("Pacific planning marker", "routines", "Imported routine draft");
  await check('document.getElementById("routine-heading").textContent === "Imported follow-up" && document.getElementById("routine-import-task").textContent === "Pacific planning marker" && document.getElementById("routine-import-setup").disabled');
  await evaluate('document.getElementById("routine-close").click()');
  await visit("Direct search notes", "files", "Attachment");
  await check('document.getElementById("sent-file-dialog").open && document.getElementById("file-text").textContent === "Direct search copy"');
  await evaluate('document.getElementById("files-back").click()');
}

async function verifyConnectedFiles(offline) {
  if (offline) {
    await evaluate('document.getElementById("connected-files-open").click()');
  } else {
    await check('document.getElementById("title").textContent === "files-agent" && !document.getElementById("connected-attach").hidden && !document.getElementById("connected-attach").disabled');
    await evaluate(`const draft = document.getElementById("task"); draft.value = "Keep this draft.";
      draft.dispatchEvent(new Event("input")); document.getElementById("connected-attach").click()`);
    await check('document.querySelector(\'#connected-files-list button[aria-label="Attach huge.bin"]\')?.disabled && document.getElementById("connected-files-target").textContent.includes("files-agent")');
  }
  const open = 'document.querySelector(\'#connected-files-list button[aria-label="Open Team blue"]\')';
  await check('Boolean(' + open + ')');
  await evaluate(open + '.click()');
  await check('document.getElementById("connected-files-path").textContent === "Connected folder / Team blue" && document.getElementById("connected-files-list").textContent.includes("Policy & notes.txt")');
  if (offline) {
    await check('!document.querySelector(\'#connected-files-list button[aria-label^="Attach"]\')');
    await evaluate('document.getElementById("connected-files-up").click()');
    await check('Boolean(' + open + ')');
    return;
  }
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("connected-files-dialog").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const { data } = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-connected-files.png"), Buffer.from(data,"base64"));
  }
  await evaluate('document.querySelector(\'#connected-files-list button[aria-label="Attach Policy & notes.txt"]\').click()');
  await check('!document.getElementById("connected-files-dialog").open && document.getElementById("task").value === "Keep this draft." && document.getElementById("direct-draft-files").textContent.includes("Policy & notes.txt") && !document.getElementById("tasks").textContent.includes("Policy & notes.txt")');
  await evaluate('document.getElementById("composer").requestSubmit()');
  await check('document.getElementById("direct-draft-files").hidden && document.getElementById("tasks").textContent.includes("Policy & notes.txt")');
  await evaluate(`(() => {
    const real = window.fetch.bind(window);
    window.fetch = (input, init) => {
      if (typeof input !== "string" || !input.startsWith("/api/drive-files")) return real(input,init);
      const url = new URL(input,location.origin);
      const path = url.searchParams.get("path");
      if (url.pathname.endsWith("/status")) return Promise.resolve(Response.json({configured:true}));
      if (url.pathname.endsWith("/file")) return Promise.resolve(path === "reports/notes" ? new Response("Drive export fixture",{headers:{
        "Content-Disposition":"attachment; filename*=UTF-8''Launch%20notes.docx"}}) : new Response(null,{status:404}));
      return Promise.resolve(Response.json({configured:true,path,label:path ? "Project / Reports" : "Project",entries:path ?
        [{id:"notes",name:"Launch notes",folder:false,bytes:null,attachable:true},{id:"protected",name:"Restricted",folder:false,bytes:3,attachable:false}] :
        [{id:"reports",name:"Reports",folder:true,bytes:null,attachable:false}],truncated:false}));
    };
    document.getElementById("connected-attach").click();
  })()`);
  await check('!document.getElementById("connected-files-source-field").hidden');
  await evaluate(`const driveSource = document.getElementById("connected-files-source"); driveSource.value = "drive"; driveSource.dispatchEvent(new Event("change"));`);
  const reports = `document.querySelector('#connected-files-list [aria-label="Open Reports"]')`;
  await check(`Boolean(${reports})`);
  await evaluate(`${reports}.click()`);
  const notes = `document.querySelector('#connected-files-list [aria-label="Attach Launch notes"]')`;
  await check(`Boolean(${notes}) && document.querySelector('#connected-files-list [aria-label="Attach Restricted"]').disabled && document.getElementById("connected-files-path").textContent === "Google Drive / Project / Reports"`);
  await evaluate(`${notes}.click()`);
  await check('!document.getElementById("connected-files-dialog").open && document.getElementById("direct-draft-files").textContent.includes("Launch notes.docx")');
  await evaluate(`document.getElementById("task").value = "Read this Drive export."; document.getElementById("task").dispatchEvent(new Event("input")); document.getElementById("composer").requestSubmit()`);
  await check('document.getElementById("direct-draft-files").hidden && document.getElementById("tasks").textContent.includes("Launch notes.docx")');
}

function noticeFixture(tab) {
  if (location.protocol !== "http:") return;
  window.fakeNotifications = [];
  class NotificationFixture {
    static get permission() { return localStorage.getItem("fixture-permission") || "default"; }
    static async requestPermission() {
      localStorage.setItem("fixture-permission","granted");
      localStorage.setItem("fixture-permission-count", String(Number(localStorage.getItem("fixture-permission-count")) + 1));
      return "granted";
    }
    constructor(title, options) {
      const records = JSON.parse(localStorage.getItem("fixture-desktop-alerts") || "[]");
      records.push({title, options, tab});
      localStorage.setItem("fixture-desktop-alerts",JSON.stringify(records));
      this.tag = options.tag;
      window.fakeNotifications.push(this);
    }
    close() { this.onclose?.(); }
  }
  Object.defineProperty(window, "Notification", {value:NotificationFixture, configurable:true});
}

async function verifyDesktopNotices() {
  await evaluate('(' + noticeFixture.toString() + ')("first"); window.desktopNotices.render()');
  const toggle = 'document.getElementById("desktop-notices-toggle")';
  const records = 'JSON.parse(localStorage.getItem("fixture-desktop-alerts") || "[]")';
  const cursor = 'JSON.parse(localStorage.getItem("swarmhub-desktop-notices-v1-checkpoint") || "{}").cursor';
  const choose = (name) => '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes(' + JSON.stringify(name) + '))';
  const step = async (gate) => {
    const before = await evaluate(cursor);
    await writeFile(join(temp, "notice-" + gate), "");
    await check(cursor + ' > ' + before);
  };
  await cdp("Page.bringToFront");
  await cdp("Emulation.setFocusEmulationEnabled", {enabled:true});
  await check('document.getElementById("title").textContent === "notice-active" && !document.getElementById("activity-open").disabled && document.hasFocus()');
  await evaluate('document.getElementById("activity-open").click(); document.querySelector(".desktop-notices summary").click()');
  await check(toggle + '.textContent === "Enable desktop notifications" && Notification.permission === "default"');
  await evaluate(toggle + '.click()');
  try {
    await check('document.getElementById("desktop-notices-status").textContent.startsWith("Desktop notifications are on") && Number.isSafeInteger(' + cursor + ')');
  } catch (error) {
    const state = await evaluate('({status:document.getElementById("desktop-notices-status").textContent, disabled:' + toggle
      + '.disabled, permission:Notification.permission, enabled:JSON.parse(localStorage.getItem("swarmhub-desktop-notices-v1")||"{}").enabled, checkpoint:'
      + cursor + ', locked:typeof navigator.locks?.request, secure:isSecureContext, visible:!document.hidden})');
    throw new Error(error.message + " Browser state: " + JSON.stringify(state));
  }
  assert.equal(await evaluate('localStorage.getItem("fixture-permission-count")'), "1");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("activity-dialog").close()');
  await step("focused");
  assert.deepEqual(await evaluate(records), []);
  await evaluate(choose("notice-muted") + '.click(); document.getElementById("details-toggle").click()');
  await check('!document.getElementById("profile-desktop-alerts").hidden && document.getElementById("profile-desktop-alerts-enabled").checked');
  await evaluate('document.getElementById("profile-desktop-alerts-enabled").click()');
  await check('!document.getElementById("profile-desktop-alerts-enabled").checked');
  await evaluate(choose("notice-active") + '.click()');
  await step("muted");
  assert.deepEqual(await evaluate(records), []);

  const {targetId} = await cdp("Target.createTarget", {url:"about:blank",background:true});
  const {sessionId} = await cdp("Target.attachToTarget", {targetId,flatten:true});
  await cdp("Page.navigate", {url:origin}, sessionId);
  await waitFor(() => evaluate('document.getElementById("core-status")?.textContent === "Workspace locked"',sessionId), "Second tab did not load.");
  await evaluate('(' + noticeFixture.toString() + ')("second")',sessionId);
  await evaluate('document.getElementById("unlock").click(); document.getElementById("token").value = ' + JSON.stringify(token)
    + '; document.getElementById("access-form").requestSubmit()',sessionId);
  await waitFor(() => evaluate('!document.getElementById("activity-open").disabled && !!window.desktopNotices',sessionId),
    "Second tab did not connect.");
  await step("background");
  await check(records + '.length === 1');
  await sleep(4250);
  const [item] = await evaluate(records);
  assert.deepEqual(await evaluate(records), [{title:"SwarmHub",options:{body:"A new reply or result is ready.",tag:"swarmhub-activity"},tab:item.tab}]);
  const owner = item.tab === "second" ? sessionId : undefined;
  await evaluate('window.fakeNotifications[0].onclick(new Event("click",{cancelable:true}))', owner);
  await waitFor(() => evaluate('document.querySelector("#archive-items .archive-match")?.textContent.includes("Private background result is ready.")',owner),
    "Notification did not open the saved reply.");
  await writeFile(join(temp, "notice-attention"), "");
  await check(records + '.length === 2');
  const attention = (await evaluate(records))[1];
  assert.deepEqual(attention.options, {body:"A request needs your attention.",tag:"swarmhub-attention"});
  const alertTab = attention.tab === "second" ? sessionId : undefined;
  await evaluate('window.fakeNotifications.find(item=>item.tag==="swarmhub-attention").onclick(new Event("click",{cancelable:true}))',alertTab);
  await waitFor(() => evaluate('document.getElementById("attention-dialog").open && document.getElementById("attention-list").textContent.includes("Which report section")',alertTab),
    "Request notification did not open Needs attention.");
  await writeFile(join(temp, "notice-webhook"), "");
  await check(records + '.length === 3');
  const webhook = (await evaluate(records))[2];
  assert.deepEqual(webhook.options, {body:"A request needs your attention.",tag:"swarmhub-attention"});
  const webhookTab = webhook.tab === "second" ? sessionId : undefined;
  await evaluate('window.fakeNotifications.filter(item=>item.tag==="swarmhub-attention").at(-1).onclick(new Event("click",{cancelable:true}))',webhookTab);
  await waitFor(() => evaluate('document.getElementById("attention-list").textContent.includes("Webhook reviews") && !document.getElementById("attention-list").textContent.includes("Private webhook fixture payload")',webhookTab),
    "Webhook notification did not open the attention inbox.");
  await evaluate(toggle + '.click()');
  await check(toggle + '.textContent === "Enable desktop notifications"');
  await waitFor(() => evaluate(toggle + '.textContent === "Enable desktop notifications"',sessionId), "Second tab did not turn off alerts.");
  await cdp("Target.closeTarget", {targetId});
}

async function verifyWebhookReview() {
  await check('document.getElementById("attention-count").textContent === "2"');
  assert.equal(await evaluate('document.getElementById("mobile-attention").getClientRects().length'), 0);
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.getElementById("mobile-attention").getClientRects().length === 1');
  await evaluate('document.getElementById("mobile-attention").click()');
  const items = '[...document.querySelectorAll("#attention-list button")].filter(button => button.textContent.includes("Review incoming events"))';
  await check(items + '.length === 2 && !document.getElementById("attention-list").textContent.includes("Dismiss fixture")');
  await evaluate(items + '[0].click()');
  const entries = 'document.getElementById("routine-review-items")';
  await check(entries + '.querySelector("details[open] pre")?.textContent.includes("Dismiss fixture") && document.getElementById("routine-runs").textContent.includes("No runs yet")');
  await evaluate(entries + '.querySelector("li:has(details[open]) button:last-child").click()');
  await check('document.getElementById("attention-count").textContent === "1" && document.getElementById("routine-back").textContent === "Back to Needs attention"');
  await evaluate('document.getElementById("routine-back").click()');
  await check(items + '.length === 1');
  await evaluate(items + '[0].click()');
  await check(entries + '.querySelector("details[open] pre")?.textContent.includes("<em>Review fixture</em>") && !' + entries + '.querySelector("em")');
  await check('!' + entries + '.querySelector("button").disabled');
  await evaluate(entries + '.querySelector("button").click()');
  await check(entries + '.textContent.includes("No events awaiting review.") && document.getElementById("routine-runs").textContent.includes("Webhook") && document.getElementById("attention-count").hidden');
  await check('document.getElementById("mobile-attention").hidden');
  await check('!document.getElementById("routine-edit").disabled');
  await evaluate('document.getElementById("routine-edit").click()');
  await check('document.getElementById("routine-review-enabled").checked && !document.getElementById("routine-filter-editor").hidden');
}

async function verifyVault() {
  await evaluate('document.getElementById("vault-open").click()');
  await check('!document.getElementById("vault-new").disabled && document.getElementById("vault-list").textContent.includes("Used by Connected files") && document.getElementById("vault-missing").textContent.includes("Needed by Slack events")');
  await evaluate('document.querySelector("#vault-missing button").click()');
  await check('document.getElementById("vault-name").value === "Slack credential" && document.getElementById("vault-name").readOnly && document.activeElement.id === "vault-value"');
  await evaluate('document.getElementById("vault-cancel").click()');
  await check('!document.getElementById("vault-new").disabled');
  await evaluate('document.getElementById("vault-new").click()');
  await check('document.getElementById("vault-value").type === "password" && document.getElementById("vault-value").value === ""');
  await evaluate(`document.getElementById("vault-name").value = "Browser fixture";
    document.getElementById("vault-value").value = "fixture temporary secret";
    document.getElementById("vault-form").requestSubmit();`);
  const replace = 'document.querySelector("#vault-list [aria-label=\\"Replace value for Browser fixture\\"]")';
  await check('Boolean(' + replace + ') && document.getElementById("vault-value").value === "" && !document.getElementById("vault-dialog").textContent.includes("fixture temporary secret")');
  await evaluate(replace + '.click()');
  await check('document.getElementById("vault-name").readOnly && document.getElementById("vault-value").value === ""');
  await evaluate(`document.getElementById("vault-value").value = "fixture replacement secret";
    document.getElementById("vault-form").requestSubmit();`);
  await check('Boolean(' + replace + ') && document.getElementById("vault-status").textContent === "Secret saved."');
  await evaluate(`document.querySelector('#vault-list [aria-label="Rename for Browser fixture"]').click()`);
  await check('document.getElementById("vault-value").hidden && document.getElementById("vault-value").value === "" && document.activeElement.id === "vault-name"');
  await evaluate(`document.getElementById("vault-name").value = "Renamed fixture";
    document.getElementById("vault-form").requestSubmit();`);
  await check('document.getElementById("vault-list").textContent.includes("Renamed fixture") && document.getElementById("vault-status").textContent === "Secret renamed."');
  await evaluate(`window.confirm = () => true; document.querySelector('#vault-list [aria-label="Remove for Renamed fixture"]').click()`);
  await check('!document.getElementById("vault-list").textContent.includes("Renamed fixture") && document.getElementById("vault-status").textContent === "Secret removed."');
}

async function verifyVaultRequest() {
  await check('document.getElementById("vault-request-dialog").open');
  await check('document.getElementById("vault-request-name").textContent === "VAULT_FIXTURE_TOKEN" && document.activeElement.id === "vault-request-value"');
  await check('document.getElementById("vault-request-bot").textContent.includes("vault-requester") && document.getElementById("vault-request-label").textContent === "Report credential"');
  await check('document.getElementById("vault-request-description").textContent === "Read the synthetic report" && document.getElementById("vault-request-value").type === "password"');
  await check('!document.getElementById("vault-request-repeat").checked');
  await evaluate(`document.getElementById("vault-request-repeat").click();
    document.getElementById("vault-request-value").value = "fixture-browser-private-value";
    document.getElementById("vault-request-form").requestSubmit();`);
  await check('!document.getElementById("vault-request-dialog").open && document.getElementById("vault-request-value").value === ""');
  await check('document.getElementById("vault-request-dialog").open && document.getElementById("vault-request-name").textContent === "VAULT_FIXTURE_CANCEL"');
  await evaluate('document.getElementById("vault-request-cancel").click()');
  await check('!document.getElementById("vault-request-dialog").open');
  await evaluate('document.getElementById("vault-open").click()');
  await check('document.getElementById("vault-list").textContent.includes("VAULT_FIXTURE_TOKEN") && !document.body.innerText.includes("fixture-browser-private-value")');
  await evaluate('document.getElementById("vault-close").click()');
}

async function verifySlackEvents() {
  await evaluate('document.getElementById("routines-open").click()');
  const item = '[...document.querySelectorAll("#routine-list button")].find(button => button.textContent.includes("Slack channel review"))';
  await check('Boolean(' + item + ')');
  await evaluate(item + '.click()');
  await check('document.getElementById("routine-when").textContent === "On Slack app mention" && document.getElementById("routine-webhook-url").value.endsWith("/hooks/slack") && document.getElementById("routine-webhook-key").hidden');
  await check('document.getElementById("routine-webhook-state").textContent === "Slack signing is configured." && document.getElementById("routine-webhook-filters").textContent.includes("C123DOCS")');
  await evaluate('document.getElementById("routine-back").click()');
  await check('!document.getElementById("routine-new").disabled');
  await evaluate(`document.getElementById("routine-new").click();
    const schedule = document.getElementById("routine-kind");
    schedule.value = "slack";
    schedule.dispatchEvent(new Event("change"));`);
  await check('!document.getElementById("routine-filter-slack").hidden && [...document.querySelectorAll("#routine-filter-rules [data-rule=field]")].map(input => input.value).join("|") === "team_id|channel"');
}

async function verifyRoutineWebhook() {
  await evaluate('document.getElementById("routines-open").click()');
  const item = '[...document.querySelectorAll("#routine-list button")].find(button => button.textContent.includes("Webhook review"))';
  await check('!!' + item);
  await evaluate(item + '.click()');
  await check('document.getElementById("routine-when").textContent === "On webhook" && document.getElementById("routine-next").textContent === "Waiting for a webhook" && document.getElementById("routine-webhook-url").value.startsWith(location.origin+"/hooks/routines/")');
  await check('document.getElementById("routine-runs").textContent.includes("Webhook · Sent to agent")');
  const filters = 'document.getElementById("routine-webhook-filters")';
  await check(filters + '.children.length === 2 && ' + filters + '.textContent.includes("request.action equals “review”")');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('window.confirm=()=>true; document.getElementById("routine-webhook-key").click()');
  await check('!document.getElementById("routine-webhook-secret-box").hidden && /^[a-f0-9]{64}$/.test(document.getElementById("routine-webhook-secret").value)');
  await evaluate('document.getElementById("routine-back").click()');
  await check('document.getElementById("routine-webhook-secret").value === ""');
  await check('!!' + item);
  await evaluate(item + '.click()');
  await check('document.getElementById("routine-webhook-key").textContent === "Rotate key" && document.getElementById("routine-webhook-secret-box").hidden');
  await check('!document.getElementById("routine-edit").disabled');
  await evaluate('document.getElementById("routine-edit").click()');
  await check('!document.getElementById("routine-filter-editor").hidden && document.querySelectorAll("#routine-filter-rules fieldset").length === 2');
  await evaluate(`document.querySelector("#routine-filter-rules button").click();
    document.getElementById("routine-filter-add").click();
    const newRule = document.querySelector("#routine-filter-rules fieldset:last-child");
    newRule.querySelector('[data-rule="field"]').value = "repository.slug";
    newRule.querySelector('[data-rule="equals"]').value = "paperwork";
    document.getElementById("routine-form").requestSubmit();`);
  await check(filters + '.children.length === 2 && ' + filters + '.textContent.includes("repository.slug equals “paperwork”") && !' + filters + '.textContent.includes("department")');
  await evaluate('document.getElementById("routine-back").click()');
  const github = '[...document.querySelectorAll("#routine-list button")].find(button => button.textContent.includes("GitHub issue review"))';
  await check('Boolean(' + github + ')');
  await evaluate(github + '.click()');
  await check('document.getElementById("routine-webhook-heading").textContent === "GitHub webhook" && document.getElementById("routine-webhook-url").value.endsWith("/github") && document.getElementById("routine-next").textContent === "Waiting for a GitHub event"');
  await check(filters + '.textContent.includes("repository.full_name equals “example/docs”")');
  await check('!document.getElementById("routine-edit").disabled');
  await evaluate('document.getElementById("routine-edit").click()');
  await check('document.getElementById("routine-kind").value === "github" && !document.getElementById("routine-filter-github").hidden');
}

async function verifyRoutineOutcomes() {
  await evaluate('document.getElementById("routines-open").click()');
  const routine = '[...document.querySelectorAll("#routine-list button")].find(button => button.textContent.includes("Outcome check"))';
  await check('!!' + routine);
  await evaluate(routine + '.click()');
  const rows = 'document.getElementById("routine-runs").textContent';
  await check(rows + '.includes("Scheduled · Sent to agent") && ' + rows + '.includes("Outcome: Failed") && ' + rows + '.includes("Outcome: Succeeded") && document.getElementById("routine-test").disabled');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("routine-runs").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('document.querySelector("#routine-runs li button").click()');
  await check('document.getElementById("library").open && document.querySelector("#archive-items .archive-match")?.textContent.includes("The source report was unavailable.")');
}

async function verifyRoutineMove() {
  const agent = '[...document.querySelectorAll("#agents .agent")].find(row => row.querySelector("strong")?.textContent === "move-agent")';
  await check('Boolean(' + agent + ')');
  await evaluate(agent + '.click(); document.getElementById("details-toggle").click(); document.getElementById("agent-routines").click()');
  const routine = '[...document.querySelectorAll("#routine-list button")].find(button => button.textContent.includes("Movable review"))';
  await check('Boolean(' + routine + ')');
  await evaluate(routine + '.click()');
  await check('!document.getElementById("routine-move-box").hidden && !document.getElementById("routine-move").disabled && document.getElementById("routine-session").textContent.includes("Not connected")');
  await evaluate('document.getElementById("routine-move").click()');
  await check('document.getElementById("routine-move-box").hidden && document.getElementById("routine-session").textContent.includes("Running") && document.getElementById("routine-next").textContent === "Paused"');
  await check('document.getElementById("routine-webhook-key").textContent === "Rotate key"');
  await evaluate('document.querySelector("#routine-runs button").click()');
  await check('document.getElementById("library").open && document.querySelector("#archive-items .archive-match")?.textContent.includes("Result from the original session.")');
}

async function verifyActivity() {
  await cdp("Page.bringToFront");
  await cdp("Emulation.setFocusEmulationEnabled", {enabled:true});
  const byText = (query, text) => '[...document.querySelectorAll(' + JSON.stringify(query) + ')].find(button => button.textContent.includes(' + JSON.stringify(text) + '))';
  const author = byText("#agents button", "activity-author");
  const group = byText("#groups button", "Activity review");
  const count = 'document.getElementById("activity-count")';
  const open = 'document.getElementById("activity-open")';
  await check(count + '.textContent === "3" && ' + author + '?.querySelector(".unread-marker").textContent === "2" && ' + group + '?.querySelector(".unread-marker").textContent === "1"');
  await evaluate(open + '.click()');
  await check('document.querySelectorAll("#activity-items .activity-unread").length === 3');
  await evaluate('document.getElementById("activity-unread-only").click()');
  await check('document.querySelectorAll("#activity-items button").length === 3');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("activity-dialog").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate(byText("#activity-items button", "Background reply is ready.") + '.click()');
  await check('document.getElementById("library").open && document.querySelector("#archive-items .archive-match")?.textContent.includes("Background reply is ready.") && ' + count + '.textContent === "2"');
  await evaluate('document.getElementById("library").close(); ' + open + '.click()');
  const reply = byText("#activity-items button", "The group review is ready.");
  await check('!!' + reply);
  await evaluate(reply + '.click()');
  await check('document.querySelector("#group-messages .archive-match")?.textContent.includes("The group review is ready.") && !document.getElementById("group-latest").hidden && ' + count + '.textContent === "1"');
  await evaluate('document.getElementById("group-latest").click()');
  await check('document.getElementById("group-messages").textContent.includes("Newer group message 33") && document.getElementById("group-latest").hidden');
  await evaluate(author + '.click()');
  await check('document.getElementById("tasks").textContent.includes("Review report.txt") && ' + count + '.hidden && ' + author + '?.querySelector(".unread-marker").hidden');
  await evaluate(open + '.click()');
  await check('document.getElementById("activity-status").textContent === "No unread activity." && document.getElementById("activity-read-all").disabled');
}

async function verifyReplyMarkdown() {
  const agent = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("markdown-author"))';
  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Markdown review"))';
  await check('!!' + agent + ' && !!' + group);
  await evaluate(agent + '.click()');
  await check('document.querySelector("#tasks .reply-markdown h1")?.textContent === "Release plan" && document.querySelector("#tasks .reply-markdown li strong")?.textContent === "Confirmed" && document.querySelector("#tasks .reply-markdown tbody td")?.textContent === "Review"');
  await check('!document.querySelector("#tasks .reply-markdown img,#tasks .reply-markdown script") && document.querySelector("#tasks .reply-markdown").textContent.includes("<img src=") && document.querySelectorAll("#tasks .reply-markdown a").length === 1 && document.querySelector("#tasks .reply-markdown a").href === "https://example.test/guide" && document.querySelector("#tasks .reply-markdown a").rel.includes("noreferrer")');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.querySelector("#tasks .reply-code pre").scrollWidth > document.querySelector("#tasks .reply-code pre").clientWidth && document.querySelector("#tasks .reply-markdown").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await cdp("Page.bringToFront");
  await cdp("Emulation.setFocusEmulationEnabled", {enabled:true});
  await cdp("Browser.grantPermissions", {origin,permissions:["clipboardReadWrite","clipboardSanitizedWrite"]});
  const click = await evaluate(`(() => {
    const button = document.querySelector("#tasks .reply-code button");
    button.scrollIntoView({block:"center"});
    const rect = button.getBoundingClientRect();
    return {x:rect.x + rect.width / 2,y:rect.y + rect.height / 2};
  })()`);
  await cdp("Input.dispatchMouseEvent", {type:"mousePressed", ...click, button:"left", clickCount:1});
  await cdp("Input.dispatchMouseEvent", {type:"mouseReleased", ...click, button:"left", clickCount:1});
  const copyStatus = await waitFor(() => evaluate('document.querySelector("#tasks .reply-code-bar [role=status]").textContent'), "Copy code did not respond.");
  assert.equal(copyStatus, "Copied.", JSON.stringify(await evaluate('({focus:document.hasFocus(), secure:isSecureContext})')));
  await evaluate('navigator.clipboard.readText().then(value => window.fixtureClipboard = value)');
  await check('window.fixtureClipboard === document.querySelector("#tasks .reply-code code").textContent');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    await evaluate('document.querySelector("#tasks .reply-item").scrollIntoView({block:"start"})');
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('document.querySelector("#tasks .reply-markdown-toggle").click()');
  await check('document.querySelector("#tasks .reply-markdown").hidden && !document.querySelector("#tasks .reply-markdown-source").hidden && document.querySelector("#tasks .reply-markdown-source").textContent.includes("**Confirmed**")');
  await evaluate('document.querySelector("#tasks .thread-open").click()');
  await check('document.querySelector("#direct-thread-root summary")?.textContent === "Read full original"');
  await evaluate('document.querySelector("#direct-thread-root summary").click()');
  await check('document.querySelector("#direct-thread-root details").open && document.querySelector("#direct-thread-root h1")?.textContent === "Release plan"');
  await evaluate('document.getElementById("direct-thread-close").click()');
  await evaluate(group + '.click()');
  await check('document.querySelector("#group-messages .reply-markdown h1")?.textContent === "Release plan" && document.querySelector("#group-messages .reply-table-scroll")?.tabIndex === 0');
}

async function verifyDirectReplies(offline) {
  const author = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("reply-author"))';
  const peer = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("reply-peer"))';
  const reply = 'document.querySelector("#tasks .reply-item .direct-reply")';
  const original = 'document.querySelector("#tasks .direct-quote button")';
  const quote = 'document.getElementById("direct-reply-target")';
  await check('!!' + author + ' && !!' + peer);
  await evaluate(author + '.click()');
  if (offline) {
    await check('!!' + original + ' && !document.querySelector("#tasks .reply-item")');
    await evaluate(original + '.click()');
    await check('document.getElementById("library").open && document.querySelector("#archive-items .archive-match")?.textContent.includes("The draft uses Tuesday.")');
    await check('!document.querySelector("#archive-items .archive-match em") && document.querySelector("#archive-items .archive-match").textContent.includes("<em>Quoted literally</em>")');
    await evaluate('document.querySelector("#archive-items .archive-match .thread-open").click()');
    await check('document.getElementById("direct-thread").open && document.getElementById("direct-thread-composer").hidden && document.querySelectorAll("#direct-thread-items article").length === 30 && document.getElementById("direct-thread-root").textContent.includes("The draft uses Tuesday.")');
    await evaluate('document.getElementById("direct-thread-older").click()');
    await check('document.querySelectorAll("#direct-thread-items article").length === 35 && document.querySelector("#direct-thread-items article > p").textContent === "Use Thursday instead." && document.getElementById("direct-thread-items").textContent.includes("Thursday is confirmed.") && !document.getElementById("direct-thread-items").textContent.includes("Unrelated entry")');
    return;
  }
  await check('!document.getElementById("history-before").hidden && !' + reply);
  await evaluate('document.getElementById("history-before").click()');
  await check('!!' + reply + ' && !' + reply + '.disabled');
  await evaluate(reply + '.click()');
  await check('!' + quote + '.hidden && document.getElementById("direct-reply-excerpt").textContent.startsWith("The draft uses Tuesday.") && document.activeElement.id === "task"');
  const type = (value) => '(() => { const task = document.getElementById("task"); task.value = ' + JSON.stringify(value) + '; task.dispatchEvent(new Event("input")); })()';
  await evaluate(type("Keep this text"));
  await evaluate('document.getElementById("direct-cancel-reply").click()');
  await check(quote + '.hidden && document.getElementById("task").value === "Keep this text"');
  await evaluate(reply + '.click()');
  await evaluate(type("x".repeat(14*1024+1)));
  await check('document.getElementById("send").disabled && !document.getElementById("direct-reply-limit").hidden');
  await evaluate(type("Use Thursday instead."));
  await evaluate(peer + '.click()');
  await check(quote + '.hidden && document.getElementById("task").value === ""');
  await evaluate(author + '.click()');
  await check('!' + quote + '.hidden && document.getElementById("task").value === "Use Thursday instead." && !document.getElementById("send").disabled');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("composer").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("composer").requestSubmit()');
  await check(quote + '.hidden && !!' + original + ' && document.querySelector("#tasks .direct-quote").textContent.includes("The draft uses Tuesday.")');
  await evaluate('document.querySelector("#tasks article:has(.direct-quote) .thread-open").click()');
  await check('document.getElementById("direct-thread").open && !document.getElementById("direct-thread-composer").hidden && document.querySelector("#direct-thread-items article > p")?.textContent === "Use Thursday instead."');
  await check('document.querySelector("#direct-thread-root details")?.open === false && !document.getElementById("direct-thread-root").innerText.includes("Unquoted tail")');
  await evaluate('document.querySelector("#direct-thread-root summary").click()');
  await check('document.getElementById("direct-thread-root").innerText.includes("Unquoted tail")');
  await evaluate('document.querySelector("#direct-thread-root summary").click()');
  await evaluate('(() => { const draft = document.getElementById("direct-thread-text"); draft.value = "Keep the original venue."; draft.dispatchEvent(new Event("input")); })()');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("direct-thread").getBoundingClientRect().right <= innerWidth && document.getElementById("direct-thread-send").getBoundingClientRect().bottom <= innerHeight');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-thread.png"), Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("direct-thread-composer").requestSubmit()');
  await check('document.querySelectorAll("#direct-thread-items article").length === 2 && document.getElementById("direct-thread-items").textContent.includes("Keep the original venue.") && document.getElementById("direct-thread-text").value === ""');
  await writeFile(join(temp, "fixture.reply-release"), "");
  await check('document.querySelector("#direct-thread-items .reply-item > p")?.textContent === "I kept the original venue." && document.querySelector("#direct-thread-items .reply-item blockquote p")?.textContent === "Keep the original venue."');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-thread-answer.png"), Buffer.from(data,"base64"));
  }
}

async function verifyReactions() {
  const direct = 'document.querySelector("#tasks .reply-item .message-reaction")';
  const group = 'document.querySelector("#group-messages .group-reply .message-reaction")';
  const label = (name) => JSON.stringify("Change reaction: " + name);
  const aria = (button) => button + '?.getAttribute("aria-label")';
  const option = (name) => 'document.querySelector(\'#reaction-options button[aria-label="' + name + '"]\')';
  const card = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("reaction-author"))';
  const chat = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Reaction review"))';
  const dialog = 'document.getElementById("reaction-dialog").open';
  await check('!!' + card);
  await evaluate(card + '.click()');
  await check(aria(direct) + ' === ' + label("Like"));
  await evaluate(direct + '.focus()');
  await check(direct + ' === document.activeElement');
  await cdp("Input.dispatchKeyEvent", {type:"keyDown",key:"Enter",code:"Enter",windowsVirtualKeyCode:13,text:"\r"});
  await cdp("Input.dispatchKeyEvent", {type:"keyUp",key:"Enter",code:"Enter",windowsVirtualKeyCode:13});
  await check(dialog + ' && document.activeElement === ' + option("Like") + ' && ' + option("Like") + '.getAttribute("aria-pressed") === "true"');
  await evaluate(option("Thanks") + '.click()');
  await check('!' + dialog + ' && ' + aria(direct) + ' === ' + label("Thanks") + ' && ' + direct + ' === document.activeElement');
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-conversations").click()');
  const archive = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.includes("reaction-author"))';
  await check('!!' + archive);
  await evaluate(archive + '.click()');
  await check(aria('document.querySelector("#archive-items .reply-item .message-reaction")') + ' === ' + label("Thanks"));
  await evaluate('document.getElementById("library").close()');
  await check('!!' + chat);
  await evaluate(chat + '.click()');
  await check('!!' + group);
  await evaluate(group + '.click()');
  await check(dialog + ' && document.getElementById("reaction-remove").hidden');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("reaction-dialog").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await evaluate(option("Celebrate") + '.click()');
  await check('!' + dialog + ' && ' + aria(group) + ' === ' + label("Celebrate"));
  await evaluate(group + '.click()');
  await check(dialog + ' && !document.getElementById("reaction-remove").hidden');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("reaction-remove").click()');
  await check('!' + dialog + ' && ' + aria(group) + ' === "React to message"');
  await evaluate(group + '.click()');
  await evaluate(option("Celebrate") + '.click()');
  await check('!' + dialog + ' && ' + aria(group) + ' === ' + label("Celebrate"));
}

async function verifyEmailDrafts() {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core disconnected"');
  const row = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "email-source")';
  await check('Boolean(' + row + ')');
  await evaluate(row + '.click()');
  await check('document.querySelectorAll("#tasks [data-email-draft]").length === 2');
  const card = (index) => 'document.querySelectorAll("#tasks [data-email-draft]")[' + index + ']';
  await evaluate(card(0) + '.click()');
  await check('document.getElementById("email-draft-to").value === "reviewer@example.test" && document.getElementById("email-draft-subject").value === "Draft <review>" && document.activeElement.id === "email-draft-to"');
  assert.equal(await evaluate('document.querySelectorAll("#email-draft-dialog script,#email-draft-dialog img,#email-draft-dialog iframe").length'), 0);
  const folder = join(temp,"email-draft-downloads");
  await cdp("Page.setDownloadBehavior", {behavior:"allow", downloadPath:folder});
  await evaluate(`document.getElementById("email-draft-to").value = "qa+release@example.test, editor@example.test";
    document.getElementById("email-draft-subject").value = "Revisión: " + "café 🔍 ".repeat(14) + "fin";
    document.getElementById("email-draft-body").value = "Café notes.\\nBcc: literal@example.test\\n<img onerror=alert(1)>";
    document.getElementById("email-draft-form").requestSubmit()`);
  const file = join(folder,"swarmhub-email-draft.eml");
  const contents = await waitFor(() => readFile(file,"utf8").catch(() => ""), "Email draft did not download");
  assert.match(contents,/^X-Unsent: 1\r\n/);
  assert.ok(!contents.includes(token));
  await check('document.getElementById("email-draft-status").textContent === "Draft downloaded. No email was sent." && ' + card(0) + '.textContent === "Open email draft"');
  await evaluate('document.getElementById("email-draft-close").click(); ' + card(0) + '.click()');
  await check('document.getElementById("email-draft-to").value === "qa+release@example.test, editor@example.test" && document.getElementById("email-draft-subject").value.endsWith("fin")');
  await evaluate('document.getElementById("email-draft-close").click(); ' + card(1) + '.click()');
  await check('document.getElementById("email-draft-subject").value === "Discard me"');
  await evaluate('document.getElementById("email-draft-dismiss").click()');
  await check('document.getElementById("email-draft-status").textContent === "Email draft dismissed." && ' + card(1) + '.disabled');
}

async function verifyMemoryProposals() {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core disconnected"');
  const row = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "memory-source")';
  await check('Boolean(' + row + ')');
  await evaluate(row + '.click()');
  await check('document.querySelectorAll("#tasks [data-memory-proposal]").length === 2');
  const button = (index) => 'document.querySelectorAll("#tasks [data-memory-proposal]")[' + index + ']';
  for (const index of [0, 1]) await check(button(index) + '.textContent === "Review memory suggestion"');
  await evaluate(button(0) + '.click()');
  await check('document.getElementById("memory-proposal-text").value === "Prefer short tables for project summaries." && document.getElementById("memory-proposal-status").textContent.includes("memory-source") && !document.getElementById("memory-proposal-save").disabled');
  await evaluate('app.token = "invalid-fixture-token"; void refresh()');
  await check('document.getElementById("core-status").textContent === "Workspace locked" && !document.getElementById("memory-proposal-dialog").open && !document.getElementById("memory-proposal-text").value');
  await evaluate(`document.getElementById("unlock").click(); document.getElementById("token").value = ${JSON.stringify(token)};
    document.getElementById("access-form").requestSubmit()`);
  await check('Boolean(' + row + ')');
  await evaluate(row + '.click()');
  await check('document.querySelectorAll("#tasks [data-memory-proposal]").length === 2');
  await evaluate(button(0) + '.click()');
  await check('document.getElementById("memory-proposal-text").value === "Prefer short tables for project summaries."');
  await evaluate(`document.getElementById("memory-proposal-text").value = "Prefer compact tables for project summaries.";
    document.getElementById("memory-proposal-form").requestSubmit()`);
  await check('document.getElementById("memory-proposal-status").textContent.startsWith("Memory saved to") && ' + button(0) + '.textContent === "Memory saved"');
  await evaluate('document.getElementById("memory-proposal-close").click(); ' + button(1) + '.click()');
  await check('document.getElementById("memory-proposal-text").value === "Prefer a weekly status note."');
  await evaluate('document.getElementById("memory-proposal-dismiss").click()');
  await check('document.getElementById("memory-proposal-status").textContent === "Memory suggestion dismissed." && ' + button(1) + '.disabled');
  await evaluate('document.getElementById("memory-proposal-close").click(); document.getElementById("details-toggle").click(); document.getElementById("profile-edit").click()');
  await check('document.getElementById("profile-instructions").value === "Keep reports factual.\\n\\nPrefer compact tables for project summaries."');
}

async function verifyRoutineProposals(offline) {
  const row = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "routine-source")';
  await check('Boolean(' + row + ')');
  await evaluate(row + '.click()');
  if (!offline) {
    await check('document.getElementById("profile-session").options.length === 2');
    await evaluate(`const previousRoutineSession = document.getElementById("profile-session");
      previousRoutineSession.selectedIndex = 1;
      previousRoutineSession.dispatchEvent(new Event("change"))`);
  }
  const proposal = (name) => '[...document.querySelectorAll("#tasks article")].find(row => row.querySelector("p")?.textContent === '
    + JSON.stringify(name) + ')?.querySelector(".review-routine-proposal")';
  const review = proposal("Morning checks");
  await check(review + '?.textContent === "Review proposed routine"');
  await evaluate(review + '.click()');
  await check('document.getElementById("routine-heading").textContent === "Review proposed routine" && document.getElementById("routine-task").value === "Check the project notes." && document.getElementById("routine-kind").value === "weekdays" && document.getElementById("routine-time").value === "09:15"');
  if (offline) {
    await check('document.getElementById("routine-save").disabled && !document.getElementById("routine-proposal-dismiss").disabled && document.getElementById("routine-proposal-status").textContent.includes("reconnect")');
    await evaluate('document.getElementById("routine-cancel").click()');
    const dismiss = proposal("Discard these reminders");
    await evaluate(dismiss + '.click()');
    await check('document.getElementById("routine-name").value === "Discard these reminders" && document.getElementById("routine-kind").value === "interval"');
    await evaluate('document.getElementById("routine-proposal-dismiss").click()');
    await check('!document.getElementById("routine-dialog").open && ' + dismiss + '?.textContent === "Routine proposal dismissed" && ' + review + '?.textContent === "Review proposed routine"');
    return;
  }
  await check('document.getElementById("routine-agent").options.length === 1 && !document.getElementById("routine-save").disabled');
  await evaluate(`document.getElementById("routine-name").value = "Reviewed morning checks";
    document.getElementById("routine-task").value = "Summarize the project notes.";
    document.getElementById("routine-time").value = "10:20";
    document.getElementById("routine-form").requestSubmit()`);
  await check('document.getElementById("routine-heading").textContent === "Reviewed morning checks" && document.getElementById("routine-next").textContent === "Paused" && document.getElementById("routine-when").textContent.includes("10:20") && ' + review + '?.textContent === "Open saved routine"');
}

async function verifySkillProposals() {
  const card = (name) => `[...document.querySelectorAll("#tasks article")].find(row => row.querySelector("p")?.textContent === ${JSON.stringify(name)})`;
  const pending = (name) => `${card(name)}?.querySelector("button")`;
  await check(`!document.getElementById("history-before").hidden && !${card("Review checklist")}`);
  await evaluate('document.getElementById("history-before").click()');
  await check(`${pending("Review checklist")}?.textContent === "Review proposed skill"`);
  await evaluate(`${pending("Review checklist")}.click()`);
  await check('document.getElementById("skill-heading").textContent === "Review proposed skill" && document.getElementById("skill-name").value === "Review checklist" && document.getElementById("skill-text").value.includes("Check the numbers")');
  await evaluate('document.getElementById("skill-name").value = "Edited review checklist"; document.getElementById("skill-save").click()');
  await check('document.getElementById("skill-heading").textContent === "Edited review checklist" && !document.getElementById("skill-detail").hidden');
  await evaluate('document.getElementById("skill-close").click()');
  await check(`${pending("Review checklist")}?.textContent === "Open saved skill" && ${pending("Dismiss this proposal")}?.textContent === "Review proposed skill"`);
  await evaluate(`${pending("Dismiss this proposal")}.click()`);
  const dismiss = '[...document.querySelectorAll("#skill-form button")].find(button => button.textContent === "Dismiss proposal" && !button.hidden)';
  await check('Boolean(' + dismiss + ')');
  await evaluate(dismiss + '.click()');
  await check(`${pending("Dismiss this proposal")}?.disabled && !document.getElementById("skill-dialog").open`);
}

async function verifyDriveOAuth() {
  await evaluate('document.getElementById("connected-files-open").click()');
  await check('!document.getElementById("drive-setup").hidden && document.getElementById("drive-connect").textContent === "Connect Google Drive"');
  await evaluate('document.getElementById("drive-connect").click()');
  await check('!document.getElementById("drive-authorize").hidden && !document.getElementById("drive-check").hidden');
  const href = new URL(await evaluate('document.getElementById("drive-authorize").href'));
  assert.equal(href.origin,"https://accounts.google.com");
  assert.equal(href.searchParams.get("redirect_uri"), origin + "/drive/oauth/callback");
  assert.equal(href.searchParams.get("code_challenge_method"),"S256");
  assert.ok(!href.href.includes("fixture-client-secret") && !href.href.includes(token));
  await evaluate('document.getElementById("drive-check").click()');
  await check('document.getElementById("drive-setup-status").textContent.includes("not connected yet")');
  await evaluate(`(() => {
    const real = window.fetch.bind(window);
    let configured = true;
    window.fetch = (input,init) => {
      if (typeof input !== "string" || !input.startsWith("/api/drive-files")) return real(input,init);
      if (input.endsWith("/disconnect")) {
        configured = false;
        return Promise.resolve(Response.json({configured}));
      }
      return Promise.resolve(Response.json(input.endsWith("/status") ? {configured,uploads:false,connectable:true}
        : {configured,path:"",label:"Project",entries:[],truncated:false}));
    };
    document.getElementById("drive-check").click();
  })()`);
  await check('document.getElementById("connected-files-path").textContent === "Google Drive / Project" && document.getElementById("drive-authorize").hidden && document.getElementById("drive-setup-status").textContent.includes("available")');
  await evaluate('document.getElementById("drive-disconnect").click()');
  await check('document.getElementById("drive-disconnect").hidden && !document.getElementById("connected-files-path").textContent && document.getElementById("drive-setup-status").textContent.includes("disconnected from this workspace")');
}

async function verifyConnectedSave() {
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-files").click()');
  const file = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith("Workspace report.txt"))';
  await check('!!' + file);
  await evaluate(file + '.click()');
  await check('!document.getElementById("file-save-connected").hidden');
  await evaluate('document.getElementById("file-save-connected").click()');
  const folder = 'document.querySelector(\'#connected-files-list button[aria-label="Open Team blue"]\')';
  await check('!!' + folder);
  await evaluate(folder + '.click()');
  await check('document.getElementById("connected-files-path").textContent === "Connected folder / Team blue" && !document.getElementById("connected-save").disabled && document.getElementById("connected-save-name").value === "Workspace report.txt"');
  await evaluate('document.getElementById("connected-save-name").value = "Policy & notes.txt"; document.getElementById("connected-save").click()');
  await check('document.getElementById("connected-files-dialog").open && document.getElementById("connected-files-status").textContent.includes("already exists") && !document.getElementById("connected-save").disabled');
  await evaluate('document.getElementById("connected-save-name").value = "Published notes.txt"');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("connected-files-dialog").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const { data } = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-connected-save.png"), Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("connected-save").click()');
  await check('!document.getElementById("connected-files-dialog").open && document.getElementById("library-notice").textContent.includes("Team blue/Published notes.txt")');
  await evaluate(`(() => {
    const real = window.fetch.bind(window);
    window.driveExport = null;
    window.fetch = (input,init) => {
      if (typeof input !== "string" || !input.startsWith("/api/drive-files")) return real(input,init);
      const route = new URL(input,location.origin);
      const path = route.searchParams.get("path");
      if (route.pathname.endsWith("/status")) return Promise.resolve(Response.json({configured:true,uploads:true}));
      if (route.pathname.endsWith("/export")) {
        window.driveExport = JSON.parse(init.body);
        return Promise.resolve(Response.json({path:"Google Drive / Project / Deliveries / " + window.driveExport.name,id:"created",bytes:34},{status:201}));
      }
      return Promise.resolve(Response.json({configured:true,uploads:path === "deliveries",path,label:path ? "Project / Deliveries":"Project",
        entries:path ? [] : [{id:"deliveries",name:"Deliveries",folder:true,attachable:false,bytes:null}],truncated:false}));
    };
    document.getElementById("file-save-connected").click();
  })()`);
  await check('!document.getElementById("connected-files-source-field").hidden');
  await evaluate(`const source = document.getElementById("connected-files-source"); source.value = "drive"; source.dispatchEvent(new Event("change"));`);
  const writable = `document.querySelector('#connected-files-list [aria-label="Open Deliveries"]')`;
  await check(`Boolean(${writable}) && document.getElementById("connected-save").disabled && document.getElementById("connected-files-status").textContent.includes("can’t accept new files")`);
  await evaluate(`${writable}.click()`);
  await check('!document.getElementById("connected-save").disabled && document.getElementById("connected-save-hint").textContent.includes("separate copy")');
  assert.equal(await evaluate("window.driveExport"),null);
  await evaluate('document.getElementById("connected-save-name").value = "Final report.txt"; document.getElementById("connected-save").click()');
  await check('!document.getElementById("connected-files-dialog").open && document.getElementById("library-notice").textContent.includes("Google Drive / Project / Deliveries / Final report.txt")');
  const exported = await evaluate("window.driveExport");
  assert.equal(exported.folder,"deliveries");
  assert.equal(exported.name,"Final report.txt");
  assert.equal(exported.source.kind,"library");
  assert.ok(Number.isInteger(exported.source.id));
}

async function verifyGrokSkillImport() {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core disconnected" && !document.getElementById("grok-import-open").disabled');
  await evaluate('document.getElementById("workspace-tools").open = true; document.getElementById("grok-import-open").click()');
  const {root} = await cdp("DOM.getDocument");
  const {nodeId} = await cdp("DOM.querySelector",{nodeId:root.nodeId,selector:"#grok-import-folder"});
  await cdp("DOM.setFileInputFiles",{nodeId,files:[join(temp,"Indexed skill export")]});
  await check('document.querySelectorAll("#grok-skill-files li").length === 3 && document.getElementById("grok-skill-files").textContent.includes("Instruction file not found")');
  await check('document.getElementById("grok-skill-status").textContent.includes("unsupported skill reference") && document.getElementById("grok-skill-stage").disabled');
  assert.equal(await evaluate('document.querySelectorAll("#grok-skill-files input:not(:disabled)").length'),2);
  assert.equal(await evaluate('document.querySelectorAll("#grok-skill-files input:checked").length'),0);
  await evaluate('[...document.querySelectorAll("#grok-skill-files input:not(:disabled)")].forEach(input => input.click()); document.getElementById("grok-skill-stage").click()');
  await check('document.getElementById("grok-skill-status").textContent.includes("Open the Skills library") && document.getElementById("grok-skill-files").textContent.includes("Ready for review")');
  await evaluate('document.getElementById("grok-skill-review").click()');
  await check('document.querySelectorAll("#skill-grok-drafts button").length === 2 && !document.getElementById("skill-list").childElementCount');
  const release = '[...document.querySelectorAll("#skill-grok-drafts button")].find(button=>button.textContent.startsWith("Release review"))';
  await evaluate(release + '.click()');
  await check('document.getElementById("skill-heading").textContent === "Review Grok skill draft" && document.getElementById("skill-text").value.includes("<script>window.importedSkillRan=true</script>") && document.activeElement.id === "skill-name"');
  assert.equal(await evaluate('typeof window.importedSkillRan'),"undefined");
  await evaluate(`document.getElementById("skill-name").value = "Reviewed release notes";
    document.getElementById("skill-description").value = "After preparing a release";
    document.getElementById("skill-text").value = "Check the date and include the full changelog.";
    document.getElementById("skill-form").requestSubmit()`);
  await check('document.getElementById("skill-heading").textContent === "Reviewed release notes" && document.getElementById("skill-instructions").textContent.includes("full changelog")');
  await evaluate('document.getElementById("skill-back").click()');
  await check('document.querySelectorAll("#skill-grok-drafts button").length === 1');
  await evaluate('document.querySelector("#skill-grok-drafts button").click()');
  const dismiss = '[...document.querySelectorAll("#skill-form button")].find(button=>button.textContent === "Dismiss imported draft")';
  await check('document.getElementById("skill-name").value === "Legacy checklist" && !' + dismiss + '?.hidden');
  await evaluate(dismiss + '.click()');
  await check('document.getElementById("skill-heading").textContent === "Skills" && !document.querySelector("#skill-grok-drafts button") && document.getElementById("skill-list").textContent.includes("Reviewed release notes")');
}

async function verifyGrokImport(launching) {
  if (launching) {
    await check('document.getElementById("title").textContent === "Scout on DMT" && !document.getElementById("profile-start").disabled');
    await evaluate('document.getElementById("workspace-search-open").click()');
    await evaluate(`const query = document.getElementById("workspace-query"); query.value = "Earlier imported detail";
      query.dispatchEvent(new Event("input"));`);
    await check('document.querySelector("#workspace-search-results button")?.textContent.includes("Earlier imported detail")');
    await evaluate('document.querySelector("#workspace-search-results button").click()');
    await check('document.querySelector("#archive-items .archive-match")?.textContent.includes("Earlier imported detail")');
    await evaluate('document.getElementById("library-close").click(); document.getElementById("profile-start").click()');
    await check('document.getElementById("launch").open && document.getElementById("template").value === "" && !document.getElementById("include-instructions").checked && document.getElementById("saved-instructions-text").textContent === "Use short notes."');
    await evaluate(`const template = document.getElementById("template"); template.value = "fixture";
      template.dispatchEvent(new Event("change"));
      document.getElementById("include-instructions").checked = true;
      document.getElementById("first-task").value = "First task on Herdr";
      document.getElementById("launch-form").requestSubmit();`);
    await check('!document.getElementById("launch").open && document.getElementById("tasks").textContent.includes("First task on Herdr") && !document.getElementById("tasks").textContent.includes("Earlier imported detail")');
    await evaluate('document.getElementById("profile-grok-history").click()');
    await check('document.getElementById("archive-items").textContent.includes("Original line 44")');
    await evaluate('document.getElementById("library-close").click(); document.getElementById("routines-open").click()');
    const openDraft = async (name) => {
      const row = `[...document.querySelectorAll("#routine-drafts button")].find(button => button.textContent.startsWith(${JSON.stringify(name)}))`;
      await check('Boolean(' + row + ')');
      await evaluate(row + '.click()');
    };
    await openDraft("Morning review");
    await check('document.getElementById("routine-import-schedule").textContent === "Weekdays at 08:30 · Europe/Warsaw" && !document.getElementById("routine-import-setup").disabled');
    await evaluate('document.getElementById("routine-import-setup").click()');
    await check('document.getElementById("routine-kind").value === "weekdays" && document.getElementById("routine-task").value === "Summarize the open questions."');
    await evaluate('document.getElementById("routine-cancel").click(); document.getElementById("routine-import-back").click()');
    await openDraft("Custom timing");
    await check('document.getElementById("routine-import-schedule").textContent.includes("Choose a schedule manually")');
    await evaluate('document.getElementById("routine-import-dismiss").click()');
    await check('document.getElementById("routine-import-detail").hidden && !document.getElementById("routine-drafts").textContent.includes("Custom timing")');
    await openDraft("Old weekly job");
    await evaluate('document.getElementById("routine-import-setup").click()');
    await check('document.getElementById("routine-kind").value === "" && document.getElementById("routine-task").value === "" && document.getElementById("routine-save").textContent === "Save paused routine" && document.getElementById("routine-agent").selectedOptions[0]?.textContent === "Scout on DMT"');
    await evaluate(`const kind = document.getElementById("routine-kind"); kind.value = "interval"; kind.dispatchEvent(new Event("change"));
      document.getElementById("routine-minutes").value = "90";
      document.getElementById("routine-task").value = "Review one sample note.";`);
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const { data } = await cdp("Page.captureScreenshot", {format:"png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-grok-routine.png"), Buffer.from(data,"base64"));
    }
    await evaluate('document.getElementById("routine-form").requestSubmit()');
    await check('document.getElementById("routine-next").textContent === "Paused" && document.getElementById("routine-toggle").textContent === "Resume" && document.getElementById("routine-runs").textContent.includes("No runs yet.")');
    return;
  }
  await evaluate('document.getElementById("grok-import-open").click()');
  const { root } = await cdp("DOM.getDocument");
  const { nodeId } = await cdp("DOM.querySelector", {nodeId: root.nodeId, selector: "#grok-import-folder"});
  await cdp("DOM.setFileInputFiles", {nodeId, files: [join(temp, "Grok export")]});
  await check('document.querySelectorAll("#grok-import-preview li").length === 2 && !document.getElementById("grok-import-save").disabled');
  const info = 'document.getElementById("grok-import-preview").textContent';
  await check(info + '.includes("Workspace Scout") && ' + info + '.includes("Read-only group archive") && ' + info + '.includes("3 routine drafts") && app.profiles.length === 0');
  await check(info + '.includes("2 attachment references") && ' + info + '.includes("1 local file ready to import")');
  await evaluate('document.querySelector("#grok-import-preview details summary").click()');
  await check('document.querySelector("#grok-import-preview details[open] p")?.textContent === "Use headings in research notes."');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("grok-import-dialog").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const { data } = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-grok-import.png"), Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("grok-import-save").click()');
  await check('document.getElementById("grok-import-status").textContent.startsWith("Saved ")');
  assert.match(await evaluate('document.getElementById("grok-import-status").textContent + "\\n" + document.getElementById("grok-import-preview").textContent'),
    /Saved 2 bundles · 37 new messages/);
  await evaluate('document.getElementById("grok-import-history").click()');
  const group = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith("Migration review"))';
  await check('!!(' + group + ')');
  await evaluate(group + '.click()');
  await check('document.getElementById("archive-items").textContent.includes("Archived group answer.") && document.getElementById("archive-items").textContent.includes("Reviewer")');
  await evaluate('document.getElementById("library-close").click()');
  const scout = '[...document.querySelectorAll("#agents .agent")].find(button => button.querySelector("strong").textContent === "Workspace Scout")';
  await check('!!(' + scout + ')');
  await evaluate(scout + '.click(); document.getElementById("profile-grok-history").click()');
  await check('document.getElementById("archive-items").textContent.includes("Original line 44") && !document.getElementById("archive-before").hidden');
  const downloads = join(temp, "Grok downloads");
  await cdp("Page.setDownloadBehavior", {behavior: "allow", downloadPath: downloads});
  await evaluate('document.getElementById("archive-transcript").click()');
  const transcript = await waitFor(() => readFile(join(downloads, "Workspace-Scout.txt"), "utf8").catch(() => ""), "Archive transcript download failed");
  assert.match(transcript, /Review <em>migration<\/em> literally/);
  assert.match(transcript, /File: Plan & notes\.txt/);
  assert.match(transcript, /\[1 attachment unavailable in the export\]/);
  assert.doesNotMatch(transcript, /Never show this hidden entry|Archive attachment copied intact/);
  assert.ok(transcript.indexOf("Original line 11") < transcript.indexOf("Original line 44"));
  await evaluate('document.getElementById("archive-before").click()');
  await check('document.getElementById("archive-items").textContent.includes("Review <em>migration</em> literally") && !document.querySelector("#archive-items em") && !document.getElementById("archive-items").textContent.includes("Never show this hidden entry")');
  const copy = 'document.querySelector(\'#archive-items [data-message-id="11"] [aria-label="Download Plan & notes.txt"]\')';
  await check('Boolean(' + copy + ') && document.querySelectorAll("#archive-items .group-files button").length === 1 && document.getElementById("archive-items").textContent.includes("1 attachment unavailable")');
  await evaluate(copy + '.click()');
  assert.equal(await waitFor(() => readFile(join(downloads, "Plan & notes.txt"), "utf8").catch(() => ""), "Archived attachment download failed"),
    "Archive attachment copied intact.\n");
  await evaluate('document.getElementById("library-close").click(); document.getElementById("details-toggle").click(); document.getElementById("agent-routines").click()');
  const draft = '[...document.querySelectorAll("#routine-drafts button")].find(button => button.textContent.startsWith("Old weekly job"))';
  await check('Boolean(' + draft + ')');
  await evaluate(draft + '.click()');
  await check('document.getElementById("routine-import-schedule").textContent === "Not included in the export" && document.getElementById("routine-import-task").textContent === "Not included in the export" && document.getElementById("routine-import-setup").disabled');
}

async function verifyAvatars(copyOnly) {
  const badge = 'document.querySelector("#badge img")';
  const row = (name) => `[...document.querySelectorAll("#agents .agent")].find(el => el.querySelector("strong").textContent === ${JSON.stringify(name)})`;
  if (copyOnly) {
    await check(`${row("Avatar copy")}?.querySelector("img")?.naturalWidth === 160`);
    await evaluate(`${row("Avatar copy")}.click()`);
    await check(`document.getElementById("title").textContent === "Avatar copy" && ${badge}?.naturalWidth === 160`);
    await check(`Boolean(${row("avatar-agent")}?.querySelector("svg")) && !${row("avatar-agent")}?.querySelector("img")`);
    return;
  }
  await check('document.getElementById("title").textContent === "avatar-agent"');
  await evaluate('document.getElementById("details-toggle").click(); document.getElementById("profile-edit").click()');
  await check('document.getElementById("profile-dialog").open && document.getElementById("avatar-picker").hidden');
  await evaluate(`const style = document.getElementById("profile-avatar"); style.value = "image";
    style.dispatchEvent(new Event("change"));`);
  const { root } = await cdp("DOM.getDocument");
  const { nodeId } = await cdp("DOM.querySelector", {nodeId: root.nodeId, selector: "#avatar-file"});
  await cdp("DOM.setFileInputFiles", {nodeId, files: [join(temp, "Not an image.png")]});
  await check('document.getElementById("avatar-notice").textContent.includes("Choose a PNG") && document.getElementById("avatar-crop").hidden');
  await cdp("DOM.setFileInputFiles", {nodeId, files: [join(temp, "Wide picture.png")]});
  await check('!document.getElementById("avatar-crop").hidden');
  const color = 'document.getElementById("avatar-canvas").getContext("2d").getImageData(3,3,1,1).data.join(",")';
  await check(color + ' === "201,105,75,255"');
  await evaluate(`const x = document.getElementById("avatar-x"); x.value = "100"; x.dispatchEvent(new Event("input"));
    const z = document.getElementById("avatar-zoom"); z.value = "125"; z.dispatchEvent(new Event("input"));`);
  await check(color + ' === "55,105,190,255"');
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("avatar-canvas").getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    await evaluate('document.getElementById("avatar-picker").scrollIntoView({block:"center"})');
    const { data } = await cdp("Page.captureScreenshot", {format:"png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-avatar.png"), Buffer.from(data,"base64"));
  }
  await evaluate('document.getElementById("profile-subtitle").value = "Studio"; document.getElementById("profile-form").requestSubmit()');
  await check(`!document.getElementById("profile-dialog").open && ${badge}?.naturalWidth === 160 && ${row("avatar-agent")}?.querySelector("img")?.naturalWidth === 160`);
  await cdp("Page.reload");
  await check(`${badge}?.naturalWidth === 160 && document.getElementById("tasks").textContent.includes("Keep this history")`);
  await evaluate('document.getElementById("details-toggle").click(); document.getElementById("profile-edit").click()');
  await check('document.getElementById("avatar-existing").querySelector("img")?.naturalWidth === 160 && !document.getElementById("avatar-existing").hidden && document.getElementById("avatar-crop").hidden');
}

async function verifySections(offline) {
  const row = (name) => `[...document.querySelectorAll("#agents .agent")].find(el => el.querySelector("strong").textContent === ${JSON.stringify(name)})`;
  const bucket = (name) => `[...document.querySelectorAll("#agents .roster-bucket")].find(el => el.querySelector(".roster-bucket-title span").textContent === ${JSON.stringify(name)})`;
  const contains = (name, section) => `${row(name)}?.closest(".roster-bucket") === ${bucket(section)} && Boolean(${bucket(section)})`;
  const selectSection = (name) => evaluate(`
    const to = document.getElementById("move-section-destination");
    to.value = [...to.options].find(option => option.textContent === ${JSON.stringify(name)}).value;
    to.dispatchEvent(new Event("change"));
    document.getElementById("move-section-form").requestSubmit();
  `);
  const move = 'document.getElementById("move-section-dialog")';
  await check(`!!(${row("atlas")}) && ${contains("summit", "Pinned")}`);
  if (offline) {
    await evaluate(`${row("atlas")}.focus()`);
    await cdp("Input.dispatchKeyEvent", {type:"keyDown", key:"F10", code:"F10", modifiers:8, windowsVirtualKeyCode:121});
    await cdp("Input.dispatchKeyEvent", {type:"keyUp", key:"F10", code:"F10", modifiers:8, windowsVirtualKeyCode:121});
    await check(move + '.open');
    await selectSection("Client delivery");
    await check('!' + move + '.open && ' + contains("atlas", "Client delivery"));
    await cdp("Page.reload");
    await check(contains("atlas", "Client delivery"));
    await evaluate(`${row("atlas")}.click()`);
    await check('document.getElementById("tasks").textContent.includes("Keep atlas history")');
    return;
  }
  await check(contains("atlas", "Unsectioned") + ` && !(${row("private")})`);
  const point = await evaluate(`(() => {
    const agent = ${row("atlas")};
    agent.scrollIntoView({block:"nearest"});
    const rect = agent.getBoundingClientRect();
    return {x:rect.x + rect.width / 2,y:rect.y + rect.height / 2};
  })()`);
  await cdp("Input.dispatchMouseEvent", {type:"mousePressed", ...point, button:"right", clickCount:1});
  await cdp("Input.dispatchMouseEvent", {type:"mouseReleased", ...point, button:"right", clickCount:1});
  await check(move + '.open && document.getElementById("move-section-agent").textContent === "atlas"');
  await evaluate(`const dest = document.getElementById("move-section-destination"); dest.value = "new";
    dest.dispatchEvent(new Event("change")); document.getElementById("move-section-name").value = "Client work";
    document.getElementById("move-section-form").requestSubmit()`);
  await check('!' + move + '.open && ' + contains("atlas", "Client work"));
  await evaluate('document.getElementById("sections-open").click(); document.querySelector(\'button[aria-label="Rename Client work"]\').click()');
  await evaluate('document.getElementById("section-name").value = "Client delivery"; document.getElementById("section-form").requestSubmit()');
  try {
    await check(contains("atlas", "Client delivery") + ' && !!document.querySelector(\'button[aria-label="Rename Client delivery"]\')');
  } catch (error) {
    const observed = await evaluate(`({
      error: document.getElementById("section-error").textContent,
      sections: app.sections,
      controls: document.getElementById("sections-list").textContent,
      roster: document.getElementById("agents").textContent,
    })`);
    throw new Error(error.message + " " + JSON.stringify(observed));
  }
  await evaluate('document.getElementById("sections-close").click()');
  const heading = bucket("Client delivery") + '.querySelector(".roster-bucket-title")';
  await evaluate(heading + '.click()');
  await check(heading + '.getAttribute("aria-expanded") === "false"');
  await evaluate(`const filter = document.getElementById("search"); filter.value = "client delivery"; filter.dispatchEvent(new Event("input"))`);
  await check(heading + `.getAttribute("aria-expanded") === "true" && ${contains("atlas", "Client delivery")} && !(${row("summit")})`);
  await evaluate('filter.value = ""; filter.dispatchEvent(new Event("input"))');
  await check(heading + '.getAttribute("aria-expanded") === "false"');
  await evaluate(heading + '.click()');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    await evaluate('document.getElementById("agents").scrollIntoView({block:"end"})');
    const { data } = await cdp("Page.captureScreenshot", { format: "png" });
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-sections.png"), Buffer.from(data, "base64"));
  }
  await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
  await evaluate(`${row("atlas")}.click(); document.getElementById("details-toggle").click(); document.getElementById("profile-move-section").click()`);
  await check(move + '.open && document.documentElement.scrollWidth <= innerWidth');
  await selectSection("Planning");
  await check('!' + move + '.open && ' + contains("atlas", "Planning"));
  await evaluate('document.getElementById("close-details").click(); document.getElementById("show-agents").click()');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await evaluate('document.getElementById("sections-open").click(); document.querySelector(\'button[aria-label="Remove Planning"]\').click()');
  await check('document.getElementById("section-remove-help").textContent.includes("Unsectioned")');
  await evaluate('document.getElementById("section-form").requestSubmit()');
  await check('!' + bucket("Planning") + ' && ' + contains("atlas", "Unsectioned") + ' && ' + contains("summit", "Pinned"));
  await evaluate('document.getElementById("sections-close").click(); document.getElementById("show-hidden-agents").click()');
  await check(`Boolean(${row("private")}) && !(${row("atlas")}) && !document.querySelector("#agents .roster-bucket")`);
}

async function verifyProfileCreation(launching) {
  const field = 'document.getElementById("profile-first-task")';
  const row = '[...document.querySelectorAll("#agents button")].find(button => button.querySelector("strong")?.textContent === "Café research")';
  const draft = "Review the project notes.";
  if (!launching) {
    await evaluate('document.getElementById("profile-new").click()');
    await check('document.getElementById("profile-create-dialog").open && document.activeElement.id === "profile-create-name"');
    await evaluate('document.getElementById("profile-create-name").value = "   "; document.getElementById("profile-create-form").requestSubmit()');
    await check('!document.getElementById("profile-create-error").hidden');
    await evaluate('document.getElementById("profile-create-name").value = " Café research "; document.getElementById("profile-create-form").requestSubmit()');
    await check('document.getElementById("title").textContent === "Café research" && !document.getElementById("profile-first-compose").hidden && document.activeElement.id === "profile-first-task"');
  } else {
    await check('Boolean(' + row + ')');
    await evaluate(row + '.click()');
  }
  await check('document.getElementById("profile-empty").textContent === "No messages yet." && !document.getElementById("launch").open');
  await evaluate(field + '.value = ' + JSON.stringify(draft) + '; ' + field + '.dispatchEvent(new Event("input"))');
  if (!launching) {
    await check('document.getElementById("profile-first-review").disabled');
    await evaluate('window.profileCreationBeforeReload = true');
    await cdp("Page.reload");
    await check('!window.profileCreationBeforeReload && Boolean(' + row + ')');
    await evaluate(row + '.click()');
    await check(field + '.value === ' + JSON.stringify(draft));
    return;
  }
  await evaluate(`document.getElementById("new").click();
    document.getElementById("first-task").value = "Separate template draft";
    document.getElementById("cancel-launch").click();
    document.getElementById("profile-first-compose").requestSubmit()`);
  await check('document.getElementById("launch").open && document.getElementById("name").readOnly && document.getElementById("launch-profile-display").textContent === "Café research" && document.getElementById("first-task").value === ' + JSON.stringify(draft));
  await evaluate(`document.getElementById("first-task").value = "Review the edited project notes.";
    document.getElementById("cancel-launch").click()`);
  await check(field + '.value === "Review the edited project notes."');
  await evaluate('document.getElementById("new").click()');
  await check('document.getElementById("first-task").value === "Separate template draft"');
  await evaluate(`document.getElementById("cancel-launch").click();
    document.getElementById("profile-first-compose").requestSubmit();
    const profileTemplate = document.getElementById("template");
    profileTemplate.value = "fixture";
    profileTemplate.dispatchEvent(new Event("change"));
    document.getElementById("launch-form").requestSubmit()`);
  await check('document.getElementById("title").textContent === "Café research" && document.getElementById("profile-first-compose").hidden && document.getElementById("output").textContent.includes("fixture received: Review the edited project notes.")');
  assert.equal(await evaluate('readTabDraft("profile-first", app.selectedProfile)'), undefined);
}

async function verifyProfileCopy(launching) {
  if (!launching) {
    await check('document.getElementById("title").textContent === "Client research"');
    await evaluate('document.getElementById("details-toggle").click(); document.getElementById("profile-duplicate").click()');
    await check('document.getElementById("duplicate-dialog").open && document.getElementById("duplicate-name").value === "Client research copy"');
    await evaluate(`document.getElementById("duplicate-name").value = "West research";
      document.getElementById("duplicate-form").requestSubmit()`);
    await check('!document.getElementById("duplicate-dialog").open && document.getElementById("title").textContent === "West research"');
    await check('document.getElementById("profile-start").disabled && document.getElementById("profile-empty").textContent.includes("1 copied routine") && document.getElementById("tasks").hidden');
    await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
    await evaluate('if (!document.getElementById("details").hidden) document.getElementById("close-details").click()');
    await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("profile-start").getBoundingClientRect().width > 0');
    await cdp("Emulation.clearDeviceMetricsOverride");
    await evaluate('document.getElementById("details-toggle").click()');
    await check('document.getElementById("agent-model").textContent === "Fixture Sonnet" && document.querySelector("#badge svg")');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-copy.png"), Buffer.from(data, "base64"));
    }
    return;
  }
  const roster = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("West research"))';
  await check('!!' + roster);
  await evaluate(roster + '.click()');
  await check('document.getElementById("title").textContent === "West research" && document.getElementById("profile-start").textContent === "Start first session" && !document.getElementById("profile-start").disabled');
  await evaluate('document.getElementById("profile-start").click()');
  await check('document.getElementById("launch").open && document.getElementById("template").value === "claude-copy-source" && document.getElementById("launch-model").value === "sonnet[1m]" && document.getElementById("collect-results").checked && document.getElementById("saved-instructions-text").textContent === "Keep source notes."');
  await evaluate(`document.getElementById("first-task").value = "West first task";
    document.getElementById("launch-form").requestSubmit()`);
  await check('!document.getElementById("launch").open && document.getElementById("title").textContent === "West research" && document.getElementById("tasks").textContent.includes("West first task") && !document.getElementById("tasks").textContent.includes("Original scope and history") && document.getElementById("profile-session").options.length === 1');
}

async function verifyProfiles() {
  await check('document.querySelector("#profile-session option") !== null');
  await evaluate(`document.getElementById("new").click();
    document.getElementById("template").value = "fixture";
    document.getElementById("name").value = "browser-peer";
    document.getElementById("first-task").value = "another workspace profile";
    document.getElementById("launch-form").requestSubmit()`);
  await check('document.getElementById("title").textContent === "browser-peer"');
  await evaluate(`[...document.querySelectorAll("#agents button")]
    .find(button => button.querySelector("strong").textContent === "browser-test").click();
    document.getElementById("details-toggle").click();
    document.getElementById("profile-edit").click();
    document.getElementById("profile-name").value = "Studio Research";
    document.getElementById("profile-subtitle").value = "Market notes";
    document.getElementById("profile-avatar").value = "target";
    document.getElementById("profile-pin").checked = true;
    document.getElementById("profile-form").requestSubmit()`);
  await check('document.querySelector("#agents button:first-child strong")?.textContent === "Studio Research" && !!document.querySelector("#badge svg")');
  await check('document.getElementById("headline").textContent.includes("Market notes") && document.getElementById("tasks").textContent.includes("browser first task")');
  await evaluate(`document.getElementById("profile-edit").click();
    document.getElementById("profile-hide").checked = true;
    document.getElementById("profile-form").requestSubmit()`);
  await check('!document.getElementById("profile-dialog").open && !document.getElementById("agents").textContent.includes("Studio Research")');
  await evaluate('document.getElementById("show-hidden-agents").click()');
  await check('document.querySelector("#agents button strong")?.textContent === "Studio Research"');
  await evaluate(`document.querySelector("#agents button").click();
    document.getElementById("profile-edit").click();
    document.getElementById("profile-hide").checked = false;
    document.getElementById("profile-form").requestSubmit()`);
  await check('!document.getElementById("profile-dialog").open && document.querySelector("#agents button:first-child strong")?.textContent === "Studio Research"');
  await cdp("Page.reload");
  await check('document.getElementById("title")?.textContent === "Studio Research" && document.getElementById("tasks").textContent.includes("browser first task")');
  await evaluate(`window.confirm = () => true;
    document.getElementById("details-toggle").click();
    document.getElementById("end").click()`);
  await check('!document.getElementById("profile-start").hidden && !document.getElementById("profile-start").disabled');
  const priorTemplate = join(temp, "config", "herdr-core", "templates", "approval-fixture.md");
  await rename(priorTemplate, priorTemplate + ".disabled");
  try {
    await evaluate('document.getElementById("refresh").click()');
    await check('!app.templates.some(template => template.name === "approval-fixture")');
    await evaluate('document.getElementById("profile-start").click()');
    await check('document.getElementById("template").value === "" && document.getElementById("description").textContent.includes("previous template is unavailable")');
    await evaluate('document.getElementById("cancel-launch").click()');
  } finally {
    await rename(priorTemplate + ".disabled", priorTemplate);
  }
  await evaluate('document.getElementById("refresh").click()');
  await check('app.templates.some(template => template.name === "approval-fixture")');
  await evaluate('document.getElementById("profile-start").click()');
  await check('document.getElementById("name").readOnly && document.getElementById("name").value === "browser-test" && document.getElementById("template").value === "approval-fixture"');
  await evaluate(`document.getElementById("first-task").value = "task from the new session";
    document.getElementById("launch-form").requestSubmit()`);
  await check('document.getElementById("profile-session").options.length === 2 && document.getElementById("tasks").textContent.includes("task from the new session") && !document.getElementById("tasks").textContent.includes("browser first task")');
  await evaluate(`const picker = document.getElementById("profile-session");
    picker.selectedIndex = 1; picker.dispatchEvent(new Event("change"))`);
  await check('document.getElementById("tasks").textContent.includes("browser first task") && !document.getElementById("tasks").textContent.includes("task from the new session") && document.getElementById("composer").hidden');
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-profiles.png"), Buffer.from(data, "base64"));
  }
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await evaluate('if (!document.getElementById("details").hidden) document.getElementById("close-details").click()');
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("profile-session").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
}

async function verifyPdf(offline) {
  const heading = (name) => 'document.getElementById("file-title").textContent === ' + JSON.stringify(name);
  const position = (page) => 'document.querySelector(".pdf-toolbar [role=status]")?.textContent === ' + JSON.stringify(`Page ${page} of 2`);
  const next = 'document.querySelector(\'.pdf-toolbar [aria-label="Next PDF page"]\')';
  const previous = 'document.querySelector(\'.pdf-toolbar [aria-label="Previous PDF page"]\')';
  if (!offline) {
    const roster = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("pdf-agent"))';
    await check('!!' + roster);
    await evaluate(roster + '.click()');
    const result = '[...document.querySelectorAll("#tasks article")].find(row => row.textContent.includes("Workspace review.pdf"))?.querySelector("button")';
    await check('!!' + result);
    await evaluate(result + '.click()');
    await check(heading("Workspace review.pdf") + ' && ' + position(1));
    await check('document.querySelector(".pdf-page canvas").width === 1400 && ' + previous + '.getAttribute("aria-disabled") === "true" && !document.getElementById("file-download").disabled');
    await check(`(() => {
      const sample = document.createElement("canvas");
      sample.width = sample.height = 1;
      const context = sample.getContext("2d");
      context.drawImage(document.querySelector(".pdf-page canvas"), 2, 2, 1, 1, 0, 0, 1, 1);
      return context.getImageData(0, 0, 1, 1).data.join(",") === "35,41,68,255";
    })()`);
    await evaluate('document.querySelector(".pdf-text summary").click()');
    await check('document.querySelector(".pdf-text pre").textContent.includes("Three reports are ready for review.") && !document.querySelector("#file-pdf-view a")');
    await evaluate('document.querySelector(".pdf-text summary").click()');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-pdf.png"), Buffer.from(data, "base64"));
    }
    await evaluate(next + '.click()');
    await check(position(2) + ' && ' + next + '.getAttribute("aria-disabled") === "true"');
    await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
    await check('document.documentElement.scrollWidth <= innerWidth && document.querySelector(".pdf-page canvas").getBoundingClientRect().width > 0 && document.querySelector(".pdf-toolbar").getBoundingClientRect().right <= innerWidth');
    await cdp("Emulation.clearDeviceMetricsOverride");
    await evaluate('document.querySelector(".pdf-text summary").click()');
    await check('document.querySelector(".pdf-text pre").textContent.includes("Confirm the dates before sharing.")');
    await evaluate(previous + '.click()');
    await check(position(1));
    for (const [name, message] of [["Locked report.pdf", "password protected"], ["Broken report.pdf", "couldn’t be previewed"]]) {
      await evaluate('document.getElementById("files-back").click()');
      const row = '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith(' + JSON.stringify(name) + '))';
      await check('!!' + row);
      await evaluate(row + '.click()');
      await check(heading(name) + ' && document.getElementById("library-notice").textContent.includes(' + JSON.stringify(message) + ') && !document.getElementById("file-download").disabled');
      await check('document.getElementById("file-pdf-view").hidden && !document.querySelector(".pdf-page canvas")');
    }
    await evaluate('document.getElementById("library-close").click()');
  }
  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("PDF review"))';
  await check('!!' + group);
  await evaluate(group + '.click()');
  const attachment = `document.querySelector('[aria-label="Preview Group review.pdf"]')`;
  await check('!!' + attachment);
  await evaluate(attachment + '.click()');
  await check(heading("Group review.pdf") + ' && ' + position(1) + ' && document.getElementById("files-back").textContent === "Back to group"');
  await evaluate('document.getElementById("files-back").click()');
  await check('!document.getElementById("library").open && !document.querySelector(".pdf-page canvas")');
}

async function verifyMedia() {
  const libraryButton = (name) => '[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith(' + JSON.stringify(name) + '))';
  const capture = async (suffix) => {
    const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
    if (screenshot && focus === "media") {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, suffix + ".png"), Buffer.from(data, "base64"));
    }
  };
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-files").click()');
  const image = libraryButton("Progress chart.png");
  await check('!!' + image);
  await evaluate(image + '.click()');
  await check('!document.getElementById("file-image-view").hidden && document.getElementById("file-image").naturalWidth === 320 && document.getElementById("file-image").naturalHeight === 180 && !document.getElementById("file-download").disabled');
  await evaluate('document.getElementById("file-zoom").click()');
  await check('document.getElementById("file-zoom").getAttribute("aria-pressed") === "true" && document.getElementById("file-image-view").classList.contains("actual")');
  await evaluate('document.getElementById("file-zoom").click()');
  await check('document.getElementById("file-zoom").getAttribute("aria-pressed") === "false"');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("file-image").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await capture("-media");
  await evaluate('document.getElementById("files-back").click()');
  const csv = libraryButton("Status table.csv");
  await check('!!' + csv);
  await evaluate(csv + '.click()');
  await check('!document.getElementById("file-table").hidden && document.querySelector("#file-table th").textContent === "Team" && document.querySelectorAll("#file-table tbody tr").length === 50');
  await check('document.querySelector("#file-table tbody tr td:nth-child(2)").textContent === "Two\\nlines" && document.getElementById("file-description").textContent.includes("Partial preview") && document.getElementById("file-table").textContent.includes("<svg onload=alert(1)>") && !document.querySelector("#file-table svg")');
  await check('document.getElementById("file-image-view").hidden && !document.getElementById("file-image").hasAttribute("src")');
  await capture("-csv");
  const openFile = async (name) => {
    await evaluate('document.getElementById("files-back").click()');
    const button = libraryButton(name);
    await check('!!' + button);
    await evaluate(button + '.click()');
  };
  await openFile("Progress recording.mp4");
  await check('!document.getElementById("file-media-view").hidden && !document.getElementById("file-video").hidden && document.getElementById("file-video").videoWidth === 160 && document.getElementById("file-video").paused && !document.getElementById("file-download").disabled');
  await evaluate('const clip = document.getElementById("file-video"); clip.muted = true; clip.play().catch(() => {});');
  await check('clip.currentTime > 0');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && clip.getBoundingClientRect().width > 0 && clip.getBoundingClientRect().right <= innerWidth');
  await cdp("Emulation.clearDeviceMetricsOverride");
  await capture("-video");
  await openFile("Audio notes.wav");
  await check('!document.getElementById("file-media-view").hidden && clip.hidden && clip.paused && !clip.hasAttribute("src") && document.getElementById("file-audio").duration === 2 && !document.getElementById("file-audio").hidden');
  await openFile("Incomplete recording.mp4");
  await check('document.getElementById("library-notice").textContent.includes("couldn’t be played") && document.getElementById("file-media-view").hidden && !document.getElementById("file-download").disabled');
  await openFile("Mislabeled.mp4");
  await check('document.getElementById("file-text").textContent.includes("<script>") && !document.getElementById("file-text").querySelector("script") && !clip.hasAttribute("src")');
  await evaluate('document.getElementById("library-close").click()');
  const group = '[...document.querySelectorAll("#groups button")].find(button => button.textContent.includes("Media review"))';
  await check('!!' + group);
  await evaluate(group + '.click()');
  const groupFile = `document.querySelector('[aria-label="Preview Group table.csv"]')`;
  await check('!!' + groupFile);
  await evaluate(groupFile + '.click()');
  await check('document.getElementById("file-title").textContent === "Group table.csv" && !document.getElementById("file-table").hidden && document.getElementById("files-back").textContent === "Back to group"');
  await evaluate('document.getElementById("files-back").click()');
  await check('!document.getElementById("library").open && !!' + groupFile);
  const groupVideo = `document.querySelector('[aria-label="Preview Group recording.webm"]')`;
  await check('!!' + groupVideo);
  await evaluate(groupVideo + '.click()');
  await check('!document.getElementById("file-media-view").hidden && clip.videoWidth === 160 && document.getElementById("file-title").textContent === "Group recording.webm" && document.getElementById("files-back").textContent === "Back to group"');
  await evaluate('document.getElementById("files-back").click()');
  await check('!document.getElementById("library").open && !clip.hasAttribute("src")');
}

async function pickRuntime() {
  await evaluate(`const search = document.getElementById("runtime-search");
    search.value = "no matching model";
    search.dispatchEvent(new Event("input"))`);
  await check('document.getElementById("template").options[0].textContent === "No runtimes match your search"');
  await evaluate(`search.value = "fixture provider fixture-model";
    search.dispatchEvent(new Event("input"))`);
  await check('document.getElementById("template").options.length === 2 && document.querySelector("#template optgroup").label === "Claude Code"');
  await evaluate(`const selectRuntime = document.getElementById("template");
    selectRuntime.value = "approval-fixture";
    selectRuntime.dispatchEvent(new Event("change"))`);
  await check('document.getElementById("runtime-labels").textContent === "Claude Code · Fixture Provider · fixture-model"');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("template").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-runtimes.png"), Buffer.from(data, "base64"));
  }
}

async function verifyInstructions() {
  await check('!!document.querySelector(".remember-task")');
  await evaluate('document.querySelector(".remember-task").click()');
  await check('document.getElementById("profile-instructions").value === "browser first task"');
  await evaluate(`document.getElementById("profile-instructions").value = "Check the dates and cite sources.";
    document.getElementById("profile-form").requestSubmit()`);
  await check('!document.getElementById("profile-dialog").open');
  await evaluate('document.getElementById("details-toggle").click(); document.getElementById("profile-draft-instructions").click()');
  await check('document.getElementById("task").value.includes("Check the dates and cite sources.") && !document.getElementById("tasks").textContent.includes("Check the dates and cite sources.")');
  await evaluate('window.confirm = () => true; document.getElementById("end").click()');
  await check('!document.getElementById("profile-start").hidden');
  await evaluate(`document.getElementById("profile-start").click();
    document.getElementById("template").value = "codex-fixture";
    document.getElementById("template").dispatchEvent(new Event("change"));
    document.getElementById("review-instructions").open = true;`);
  await check('document.getElementById("include-instructions").checked && document.getElementById("saved-instructions-text").textContent === "Check the dates and cite sources."');
  await cdp("Emulation.setDeviceMetricsOverride", {width: 375, height: 812, deviceScaleFactor: 1, mobile: true});
  await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("include-instructions").getBoundingClientRect().width > 0');
  await cdp("Emulation.clearDeviceMetricsOverride");
  if (process.env.SWARMHUB_TEST_SCREENSHOT) {
    const {data} = await cdp("Page.captureScreenshot", {format: "png"});
    await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-instructions.png"), Buffer.from(data, "base64"));
  }
  await evaluate(`document.getElementById("first-task").value = "Read the new report";
    document.getElementById("launch-form").requestSubmit()`);
  await check('document.querySelector("#tasks .launch-record p")?.textContent === "Check the dates and cite sources." && document.getElementById("agent-runtime").textContent === "Codex"');
  await check('document.querySelector("#tasks .reply-item")?.textContent.includes("Read the new report")');
  await evaluate(`const followUp = document.getElementById("task");
    followUp.value = "Read the second report"; followUp.dispatchEvent(new Event("input"));
    document.getElementById("composer").requestSubmit()`);
  await check('document.getElementById("tasks").textContent.includes("Read the second report")');
  await evaluate('document.getElementById("library-open").click(); document.getElementById("library-conversations").click()');
  await check('[...document.querySelectorAll("#library-items button")].some(button => button.textContent.startsWith("browser-test"))');
  await evaluate('[...document.querySelectorAll("#library-items button")].find(button => button.textContent.startsWith("browser-test")).click()');
  await check('document.getElementById("archive-items").textContent.includes("Read the second report") && !document.querySelector("#archive-items .remember-task")');
}

try {
  const port = await waitFor(async () => {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error("Chrome exited during startup.\n" + chromeError);
    const file = await readFile(join(profile, "DevToolsActivePort"), "utf8").catch(() => "");
    return parseInt(file, 10);
  }, "Chrome did not start", 300).catch((error) => { throw new Error(error.message + "\n" + chromeError); });
  const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((target) => target.type === "page");
  assert.ok(page);
  ws = new WebSocket(page.webSocketDebuggerUrl);
  ws.addEventListener("close", () => {
    for (const waiter of pending.values()) waiter.reject(new Error("The Chrome debugger disconnected."));
    pending.clear();
  });
  ws.addEventListener("message", ({ data }) => {
    const packet = JSON.parse(data);
    const waiter = pending.get(packet.id);
    if (!waiter) return;
    pending.delete(packet.id);
    if (packet.error) waiter.reject(new Error(packet.error.message));
    else waiter.resolve(packet.result);
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  await cdp("Page.navigate", { url: origin });
  await check('document.getElementById("core-status")?.textContent === "Workspace locked"');
  if (focus === "profile-create") {
    assert.equal(await evaluate('document.getElementById("profile-new").disabled && document.getElementById("profile-first").disabled'), true);
  }
  await evaluate(`document.getElementById("unlock").click();
    document.getElementById("token").value = ${JSON.stringify(token)};
    document.getElementById("access-form").requestSubmit()`);
  if (focus === "appearance") {
    const {verifyAppearance} = await import("./appearance-browser.mjs");
    await verifyAppearance({evaluate, check, cdp});
  } else if (focus === "desktop-teaching") {
    const {verifyDesktopTeaching} = await import("./desktop-teaching-browser.mjs");
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await verifyDesktopTeaching({evaluate, check, cdp, temp});
    console.log("Chrome verified real private X11 clicks, passive recording, editable skill review, and lock cleanup.");
  } else if (focus === "pwa") {
    const {verifyPwa} = await import("./pwa-browser.mjs");
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await verifyPwa({origin, temp, evaluate, check, cdp});
  } else if (focus === "dictation") {
    const {verifyDictation} = await import("./dictation-browser.mjs");
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await verifyDictation({evaluate, check});
    console.log("Injected recognizer verified local-only contract, explicit preparation, review, draft limits, and cleanup.");
  } else if (focus === "voice-memos") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await evaluate(`(${observeVoiceStreams})()`);
    await verifyVoiceMemos({evaluate, check});
    console.log("Chrome verified capture, playback, draft-only staging, sending, and microphone cleanup for voice memos.");
  } else if (focus === "direct-files-offline") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyOfflineDirectFile();
    console.log("Chrome verified direct file preview and download with Herdr Core offline.");
  } else if (focus === "chat-links") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await verifyChatLinks();
    console.log("Chrome verified chat links, unlock, existing drafts, and intentional session launch.");
  } else if (focus === "results-auto") {
    await check('!document.getElementById("new").disabled');
    await evaluate(`document.getElementById("new").click();
      document.getElementById("template").value = "fixture";
      document.getElementById("template").dispatchEvent(new Event("change"));
      document.getElementById("name").value = "auto-results";
      document.getElementById("first-task").value = "Produce automatic results";
      document.getElementById("collect-results").checked = true;
      document.getElementById("launch-form").requestSubmit()`);
    await check('document.getElementById("title").textContent === "auto-results" && document.querySelector("#tasks .snapshot-item button")?.textContent === "Open file"');
    await evaluate('document.querySelector("#tasks .snapshot-item button").click()');
    await check('document.getElementById("file-title").textContent === "Automatic report.txt" && document.getElementById("file-text").textContent === "The finished report"');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format: "png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("library-close").click(); document.getElementById("details-toggle").click()');
    await check('!document.getElementById("results-folder-detail").hidden && document.getElementById("results-folder-path").textContent.includes("/workspace/results/")');
    console.log("Chrome automatic result collection passed.");
  } else if (focus === "command-reviewer") {
    await check('!document.getElementById("approval-count").hidden && !document.getElementById("approvals-open").disabled');
    await evaluate('document.getElementById("workspace-tools").open = true; document.getElementById("approvals-open").click()');
    await check('document.querySelector("#approval-list button")');
    await evaluate('document.querySelector("#approval-list button").click()');
    await check('!document.getElementById("approval-reviewer").hidden && document.getElementById("approval-reviewer").textContent.includes("Would print audit.")');
    await evaluate('document.getElementById("approval-deny").click()');
    await check('!document.querySelector("#approval-list button") && !document.getElementById("approval-reviewer").textContent');
  } else if (focus === "opencode-inbox") {
    await check('document.getElementById("attention-count").textContent === "1"');
    await evaluate('document.getElementById("attention-open").click()');
    await check('document.querySelector("#attention-list button")?.textContent.includes("OpenCode · Approval requested") && document.querySelectorAll("#attention-list button").length === 1');
    await evaluate('document.querySelector("#attention-list button").click()');
    await check('document.getElementById("approval-action").textContent === "opencode-needs-input requests read" && document.getElementById("approval-path").textContent.startsWith("OpenCode") && JSON.parse(document.getElementById("approval-input").textContent).resources.join() === "permission-fixture.txt"');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format: "png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("approval-allow").click()');
    await check('document.getElementById("approval-history").textContent.includes("OpenCode · Allow once sent")');
    await evaluate('document.getElementById("approval-close").click()');
    await check('document.querySelector("#tasks .reply-item p")?.textContent === "Reply from the local test endpoint." && document.getElementById("blocked-agent").hidden');
    console.log("Chrome OpenCode approval inbox passed.");
  } else if (focus === "opencode-blocked") {
    const agent = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("opencode-needs-input"))';
    await check('!!' + agent);
    await evaluate(agent + '.click()');
    await check('!document.getElementById("blocked-agent").hidden && document.getElementById("blocked-agent-message").textContent === "This agent needs permission to continue." && document.getElementById("headline").textContent.includes("Needs attention") && document.getElementById("task").disabled');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-attention.png"), Buffer.from(data, "base64"));
    }
    await check('document.getElementById("attention-count").textContent === "1"');
    await evaluate('document.getElementById("attention-open").click()');
    await check('document.querySelector("#attention-list button")?.textContent.includes("Permission needed")');
    await evaluate('document.querySelector("#attention-list button").click()');
    await check('document.getElementById("terminal-dialog").open && document.getElementById("terminal-status").textContent.startsWith("Attached") && document.getElementById("terminal-host").textContent.toLowerCase().includes("permission")');
    await evaluate('document.querySelector("#terminal-host textarea").focus()');
    await check('document.querySelector("#terminal-host textarea") === document.activeElement && document.getElementById("terminal-host").textContent.includes("Allow once")');
    await cdp("Input.dispatchKeyEvent", {type: "keyDown", key: "Enter", code: "Enter", text: "\r", windowsVirtualKeyCode: 13});
    await cdp("Input.dispatchKeyEvent", {type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13});
    await check('document.getElementById("terminal-host").textContent.includes("Reply from the local test endpoint.")');
    await evaluate('document.getElementById("terminal-close").click()');
    await check('!document.getElementById("terminal-dialog").open && document.getElementById("blocked-agent").hidden && !document.getElementById("headline").textContent.includes("Needs attention")');
    console.log("Chrome OpenCode attention and terminal handoff passed.");
  } else if (focus === "opencode-group-preview") {
    const group = (name) => '[...document.querySelectorAll("#groups button")].find(button => button.querySelector("strong")?.textContent === ' + JSON.stringify(name) + ')';
    const own = group("OpenCode group fixture");
    const other = group("Unrelated OpenCode group fixture");
    const preview = 'document.querySelector("#group-live-drafts article")';
    const live = 'document.getElementById("group-live-drafts")';
    await check('!!' + own);
    await evaluate(own + '.click()');
    await check(preview + '?.dataset.taskId === ' + JSON.stringify(process.env.SWARMHUB_TEST_OPENCODE_GROUP_TASK) +
      ' && ' + preview + '.querySelector("strong").textContent === "local-opencode"' +
      ' && ' + preview + '.querySelector("small").textContent === "Live reply preview"' +
      ' && ' + preview + '.textContent.includes("Group reply before") && !document.querySelector("#group-messages .group-reply")');
    await evaluate(other + '.click()');
    await check(live + '.hidden && !' + preview);
    await evaluate(own + '.click()');
    await check('!!' + preview);
    assert.equal((await fetch(process.env.SWARMHUB_TEST_OPENCODE_GROUP_RELEASE)).status, 204);
    await check(live + '.hidden && !document.querySelector("#group-messages .group-reply")');
    console.log("Chrome OpenCode group live preview passed.");
  } else if (focus === "opencode") {
    const agent = '[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("local-opencode"))';
    await check('!!' + agent);
    await evaluate(agent + '.click()');
    await check('document.getElementById("title").textContent === "local-opencode" && document.querySelector("#tasks .reply-item p")?.textContent === "Reply from the local test endpoint." && !document.getElementById("task").disabled');
    await evaluate(`const task = document.getElementById("task");
      task.value = "Second local question";
      task.dispatchEvent(new Event("input"));
      document.getElementById("composer").requestSubmit()`);
    await check('!document.getElementById("reply-draft").hidden && document.getElementById("reply-draft-text").textContent === "Second reply from the local" && [...document.querySelectorAll("#tasks .reply-item strong")].filter(source => source.textContent === "OpenCode reply").length === 6');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format: "png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data, "base64"));
    }
    assert.equal((await fetch(process.env.SWARMHUB_TEST_OPENCODE_FINISH_URL)).status, 204);
    await check(`document.getElementById("title").textContent === "local-opencode" &&
      document.getElementById("reply-draft").hidden &&
      JSON.stringify([...document.querySelectorAll("#tasks .reply-item")].filter(row => row.querySelector("strong").textContent === "OpenCode reply").map(row => [row.querySelector("strong").textContent, row.querySelector("p").textContent])) ===
      JSON.stringify([["OpenCode reply", "Reply from the local test endpoint."],
        ["OpenCode reply", "Direct reply before Mini."], ["OpenCode reply", "Group reply before Mini."],
        ["OpenCode reply", "Routine reply before Mini."], ["OpenCode reply", "Reply with the switched model."],
        ["OpenCode reply", "Reply with the restored default."], ["OpenCode reply", "Second reply from the local test endpoint."]])`);
    await evaluate('document.getElementById("new").click()');
    await evaluate(`const modelSearch = document.getElementById("runtime-search");
      modelSearch.value = "Fast fixture";
      modelSearch.dispatchEvent(new Event("input"))`);
    await check('document.querySelector("#template optgroup")?.label === "OpenCode" && document.getElementById("template").options.length === 2');
    await evaluate(`const template = document.getElementById("template");
      template.value = "local-model";
      template.dispatchEvent(new Event("change"));
      const model = document.getElementById("launch-model");
      model.value = "fixture/fast";
      model.dispatchEvent(new Event("change"));
      document.getElementById("name").value = "browser-model";
      document.getElementById("first-task").value = "Model choice from browser";`);
    await check('!document.getElementById("launch-model-field").hidden && document.getElementById("runtime-labels").textContent === "OpenCode · Local fixture · Fast fixture"');
    await check('!document.getElementById("load-launch-models").hidden && !document.querySelector("#launch-model optgroup")');
    await evaluate('document.getElementById("load-launch-models").click()');
    await waitFor(() => evaluate('!document.getElementById("load-launch-models").disabled'), "OpenCode model discovery did not finish", 420);
    await check('document.querySelector("#launch-model optgroup")?.label === "Available in OpenCode" && document.getElementById("launch-model-discovery-status").textContent === "4 OpenCode models found." && model.value === "fixture/fast"');
    await evaluate(`model.value = "fixture/discovered";
      model.dispatchEvent(new Event("change"));`);
    await check('document.getElementById("runtime-labels").textContent === "OpenCode · fixture/discovered" && document.getElementById("launch-model-id-field").hidden');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format: "png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-model-picker.png"), Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("launch-form").requestSubmit()');
    await check('document.getElementById("title").textContent === "browser-model" && document.querySelector("#tasks .reply-item p")?.textContent === "Model selected: discovered"');
    await check('document.getElementById("agent-model").textContent === "fixture/discovered" && document.getElementById("agent-model").title === "fixture/discovered"');
    await evaluate('if (document.getElementById("details").hidden) document.getElementById("details-toggle").click()');
    await check('!document.getElementById("opencode-model-open").hidden');
    await evaluate('document.getElementById("opencode-model-open").click()');
    await check('document.getElementById("opencode-model-dialog").open && document.getElementById("opencode-model-current").textContent === "fixture/discovered" && document.getElementById("opencode-model-default").textContent === "fixture/default"');
    await evaluate(`const sessionModelInput = document.getElementById("opencode-model-id");
      sessionModelInput.value = "fixture/fast"; sessionModelInput.dispatchEvent(new Event("input"));`);
    await check('document.getElementById("opencode-model-review").textContent.includes("Apply fixture/fast") && !document.getElementById("opencode-model-apply").disabled');
    await evaluate('document.getElementById("opencode-model-form").requestSubmit()');
    await check('document.getElementById("opencode-model-current").textContent === "fixture/fast" && document.getElementById("opencode-model-status").textContent.includes("confirmed")');
    await evaluate(`const modelChange = document.getElementById("opencode-model-mode"); modelChange.value = "reset"; modelChange.dispatchEvent(new Event("change"));`);
    await check('document.getElementById("opencode-model-review").textContent.includes("Apply fixture/default") && !document.getElementById("opencode-model-apply").disabled');
    await evaluate('document.getElementById("opencode-model-form").requestSubmit()');
    await check('document.getElementById("opencode-model-current").textContent === "fixture/default" && document.getElementById("agent-model").title === "fixture/discovered"');
    await evaluate('document.getElementById("opencode-model-close").click()');
    console.log("Chrome OpenCode live reply and model selection passed.");
  } else if (focus === "pdf" || focus === "pdf-offline") {
    const connection = focus === "pdf" ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("library-open").disabled`);
    await verifyPdf(focus === "pdf-offline");
    console.log(`Chrome ${focus} flow passed.`);
  } else if (focus === "media" || focus === "media-offline") {
    const connection = focus === "media" ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("library-open").disabled`);
    await verifyMedia();
    console.log(`Chrome ${focus} flow passed.`);
  } else if (focus === "search" || focus === "search-offline") {
    const connection = focus === "search" ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("workspace-search-open").disabled`);
    await verifySearch(focus === "search-offline");
    console.log(`Chrome ${focus} flow passed.`);
  } else if (focus === "agent-library") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyAgentLibrary();
    console.log("Chrome verified agent library filters and offline results across sessions.");
  } else if (focus === "github-access") {
    const {verifyGitHubAccess} = await import("./github-access-browser.mjs");
    await verifyGitHubAccess({evaluate, check});
    console.log("Chrome verified per-session GitHub read grants, revocation and minimal request history.");
  } else if (focus === "github-project") {
    await verifyGitHubProject();
    console.log("Chrome browsed GitHub issues and pull requests and attached reviewed excerpts to direct and group drafts.");
  } else if (focus === "group-handoffs") {
    await verifyGroupHandoffs();
    console.log("Chrome verified group handoff review, one-recipient approval, and dismissal.");
  } else if (focus === "page-share") {
    const {verifyPageSharing} = await import("./page-sharing-browser.mjs");
    await verifyPageSharing({origin, token, evaluate, check, cdp, waitFor});
    console.log("Chrome verified an independent read-only Page viewer, live updates and revocation.");
  } else if (focus === "page-html-export") {
    await verifyPageHtmlExport();
    console.log("Chrome downloaded an exact older Page revision and opened it as a standalone file with network blocked.");
  } else if (focus === "page-checklist") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyChecklist();
    await verifyPageLinks();
    await verifyPageTables();
    console.log("Chrome verified offline checklists, revision history, Page links, tables and charts.");
  } else if (focus === "vault") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("vault-open").disabled');
    await verifyVault();
    console.log("Chrome verified write-only vault entry management with Core offline.");
  } else if (focus === "vault-request") {
    await verifyVaultRequest();
    console.log("Chrome verified masked Vault request approval and cancellation.");
  } else if (focus === "webhook-review") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected" && !document.getElementById("routines-open").disabled');
    await verifyWebhookReview();
    console.log("Chrome verified webhook event preview, approval, and dismissal.");
  } else if (focus === "slack-events") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected" && !document.getElementById("routines-open").disabled');
    await verifySlackEvents();
    console.log("Chrome verified Slack routine setup and workspace/channel conditions.");
  } else if (focus === "routine-webhooks") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected" && !document.getElementById("routines-open").disabled');
    await verifyRoutineWebhook();
    console.log("Chrome verified webhook setup, secret rotation, and run history.");
  } else if (focus === "routine-move") {
    await check('document.getElementById("core-status").textContent === "Herdr Core connected"');
    await verifyRoutineMove();
    console.log("Chrome moved a routine to its replacement session and opened the earlier result.");
  } else if (focus === "routine-outcomes") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("routines-open").disabled');
    await verifyRoutineOutcomes();
    console.log("Chrome showed routine delivery and outcomes separately and opened the saved result offline.");
  } else if (focus === "desktop-notices") {
    await verifyDesktopNotices();
    console.log("Chrome verified opt-in, muted and focused agents, cross-tab deduplication, and notification click targets.");
  } else if (focus === "activity") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("activity-open").disabled');
    await verifyActivity();
    console.log("Chrome activity, exact message navigation, and unread counts passed with Core offline.");
  } else if (focus === "reply-markdown") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected"');
    await verifyReplyMarkdown();
    console.log("Chrome rendered saved Markdown replies in direct chat, threads, and groups, with Core offline.");
  } else if (focus === "direct-replies" || focus === "direct-replies-offline") {
    const offline = focus.endsWith("-offline");
    const connection = offline ? "Herdr Core disconnected" : "Herdr Core connected";
    await check('document.getElementById("core-status").textContent === ' + JSON.stringify(connection));
    await verifyDirectReplies(offline);
    console.log(offline ? "Chrome opened the original from archived history with Core offline." : "Chrome sent a direct reply with its quoted context.");
  } else if (focus === "reactions") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyReactions();
    console.log("Chrome direct, archive, and group reactions passed with Core offline.");
  } else if (focus === "email-drafts") {
    await verifyEmailDrafts();
    console.log("Chrome verified offline email review, edited .eml download, reopening, and dismissal.");
  } else if (focus === "memory-proposals") {
    await verifyMemoryProposals();
    console.log("Chrome verified editing, saving and dismissing reviewed memory while Core is offline.");
  } else if (focus === "routine-proposals" || focus === "routine-proposals-offline") {
    const offline = focus.endsWith("-offline");
    const connection = offline ? "Herdr Core disconnected" : "Herdr Core connected";
    await check(`document.getElementById("core-status")?.textContent === ${JSON.stringify(connection)}`);
    await verifyRoutineProposals(offline);
    console.log(`Chrome routine proposal ${offline ? "review and dismissal while Core is offline" : "edit and paused adoption on a replacement session"} passed.`);
  } else if (focus === "skill-proposals") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected"');
    await verifySkillProposals();
    console.log("Chrome verified review, edits, save and dismissal of skill proposals with Core offline.");
  } else if (focus === "agent-drive-ui") {
    const get = (id) => `document.getElementById(${JSON.stringify(id)})`;
    await check('!' + get("agent-drive-open") + '.hidden');
    await evaluate(get("details-toggle") + '.click();' + get("agent-drive-open") + '.click()');
    await check(get("agent-drive-dialog") + '.open && ' + get("agent-drive-status") + '.textContent === "Read access is off."');
    await check(get("agent-drive-calls") + '.textContent.includes("Refused or failed")');
    await evaluate(get("agent-drive-change") + '.click()');
    await check(get("agent-drive-change") + '.textContent === "Revoke access" && ' + get("agent-drive-command") + '.textContent.endsWith("drive-list")');
    await evaluate(get("agent-drive-change") + '.click()');
    await check(get("agent-drive-status") + '.textContent === "Read access is off." && ' + get("agent-drive-help") + '.hidden');
    console.log("Chrome verified Google Drive grant, revocation, and per-session recent activity.");
  } else if (focus === "drive-oauth") {
    await check('!document.getElementById("connected-files-open").disabled');
    await verifyDriveOAuth();
    console.log("Chrome verified browser consent preparation and connection status.");
  } else if (focus === "connected-save") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyConnectedSave();
    console.log("Chrome saved a Library file to WebDAV with Core offline.");
  } else if (focus === "connected-files" || focus === "connected-files-offline") {
    const offline = focus.endsWith("-offline");
    const connection = offline ? "Herdr Core disconnected" : "Herdr Core connected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("connected-files-open").disabled`);
    await verifyConnectedFiles(offline);
    console.log(`Chrome WebDAV ${offline ? "browsing with Core offline" : "connected file attachment"} passed.`);
  } else if (focus === "read-approval-rules") {
    await check('!document.getElementById("approvals-open").disabled');
    await evaluate('document.querySelector("#workspace-tools summary").click(); document.getElementById("approvals-open").click()');
    await check('document.querySelector("#approval-list button")?.textContent.includes("Read reviewer")');
    await evaluate('document.querySelector("#approval-list button").click()');
    await check('!document.getElementById("approval-remember-options").hidden && document.getElementById("approval-input").textContent.includes("review-notes.md")');
    await evaluate('document.getElementById("approval-remember").click()');
    await check('document.getElementById("approval-read-rules").textContent.includes("review-notes.md") && document.getElementById("approval-history").textContent.includes("Allowed by read rule")');
    console.log("Chrome reviewed a single-file read rule and showed the automatic decision.");
  } else if (focus === "demo-preview") {
    await check('!document.getElementById("demo-banner").hidden && document.getElementById("agents").textContent.includes("Briefing agent") && document.getElementById("groups").textContent.includes("Launch planning")');
    await check('document.getElementById("groups").getBoundingClientRect().bottom < innerHeight && !document.getElementById("workspace-tools").open');
    await evaluate('[...document.querySelectorAll("#agents button")].find(button => button.textContent.includes("Briefing agent")).click()');
    await check('document.getElementById("title").textContent === "Briefing agent" && document.getElementById("tasks").textContent.includes("The release notes and FAQ are ready") && document.getElementById("output").hidden');
    await evaluate('document.getElementById("terminal-output-toggle").click()');
    await check('!document.getElementById("output").hidden && document.getElementById("output").textContent.includes("SwarmHub preview agent")');
    await evaluate('document.getElementById("terminal-output-toggle").click(); document.getElementById("work-scroll").scrollTop = 0');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format:"png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT, Buffer.from(data,"base64"));
    }
    console.log("Chrome verified the seeded demo, its banner, and a live agent conversation.");
  } else if (focus === "runtime-setup") {
    await check('document.getElementById("title").textContent === "Setup draft" && !document.getElementById("runtime-setup-draft").hidden');
    await evaluate(`const draft = document.getElementById("profile-first-task"); draft.value = "Keep this first task.";
      draft.dispatchEvent(new Event("input")); document.getElementById("runtime-setup-draft").click();`);
    await check('document.getElementById("runtime-setup").open && /none of its templates/.test(document.getElementById("runtime-setup-state").textContent) && /literal/.test(document.getElementById("runtime-setup-list").textContent)');
    await cdp("Emulation.setDeviceMetricsOverride", {width:375,height:812,deviceScaleFactor:1,mobile:true});
    await check('document.documentElement.scrollWidth <= innerWidth && document.getElementById("runtime-setup").getBoundingClientRect().right <= innerWidth');
    await cdp("Emulation.clearDeviceMetricsOverride");
    await cdp("Page.setDownloadBehavior", {behavior:"allow", downloadPath:join(temp,"runtime-download")});
    await evaluate(`const kind = document.getElementById("runtime-setup-kind"); kind.value = "opencode";
      kind.dispatchEvent(new Event("change")); document.getElementById("runtime-setup-download").click();`);
    const downloaded = await waitFor(() => readFile(join(temp,"runtime-download","opencode.md"),"utf8").catch(() => ""), "The runtime template did not download");
    assert.match(downloaded, /command: swarmhub-herdr run-opencode --api-first-task mini/);
    await writeFile(join(temp,"config","herdr-core","templates","fixture.md"), await readFile(join(temp,"fixture.md")));
    await evaluate('document.getElementById("runtime-setup-refresh").click()');
    await check('document.getElementById("runtime-setup-state").textContent.includes("1 template available.") && !!document.querySelector(\'[aria-label="Choose fixture"]\')');
    await evaluate('document.querySelector(\'[aria-label="Choose fixture"]\').click()');
    await check('document.getElementById("launch").open && document.getElementById("template").value === "fixture" && document.getElementById("launch-profile-display").textContent === "Setup draft" && document.getElementById("first-task").value === "Keep this first task."');
    await evaluate('document.getElementById("cancel-launch").click()');
    await check('!document.getElementById("launch").open && document.getElementById("profile-first-task").value === "Keep this first task."');
    console.log("Chrome verified runtime diagnostics, recipe download and first-draft handoff.");
  } else if (focus === "grok-export-helper") {
    await check('!document.getElementById("grok-import-open").disabled');
    await cdp("Page.setDownloadBehavior", {behavior:"allow", downloadPath:join(temp,"export-helper-download")});
    await evaluate('document.getElementById("grok-import-open").click(); document.querySelector("#grok-export-guide summary").click()');
    await check('document.getElementById("grok-export-guide").open && document.querySelector("#grok-export-guide code").textContent.includes("python3")');
    await evaluate('document.getElementById("grok-export-helper").click()');
    await check('document.getElementById("grok-export-helper-status").textContent.startsWith("Download started")');
    await waitFor(() => readFile(join(temp,"export-helper-download","swarmhub-grok-export.pyz")).catch(() => null), "The local export helper did not download");
    console.log("Chrome downloaded the offline Grok Bot export helper.");
  } else if (focus === "grok-skill-import") {
    await verifyGrokSkillImport();
    console.log("Chrome verified explicit indexing, staging, editing, saving, and dismissing supplied Grok skill files with Core offline.");
  } else if (focus === "grok-import" || focus === "grok-import-launch") {
    const launching = focus.endsWith("-launch");
    const connection = launching ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("grok-import-open").disabled`);
    await verifyGrokImport(launching);
    console.log(`Chrome Grok Bot ${launching ? "history search and first Herdr launch" : "export preview and offline import"} passed.`);
  } else if (focus === "profile-avatar" || focus === "profile-avatar-copy") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
    await verifyAvatars(focus === "profile-avatar-copy");
    console.log(`Chrome ${focus === "profile-avatar-copy" ? "independent copied avatar" : "avatar upload, crop and reload"} passed.`);
  } else if (focus === "roster-sections" || focus === "roster-sections-offline") {
    const offline = focus.endsWith("-offline");
    const connection = offline ? "Herdr Core disconnected" : "Herdr Core connected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("sections-open").disabled`);
    await verifySections(offline);
    console.log(`Chrome roster sections ${offline ? "offline move and reload" : "management and grouping"} passed.`);
  } else if (focus === "profile-create" || focus === "profile-create-launch") {
    const launching = focus === "profile-create-launch";
    const connection = launching ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("profile-new").disabled`);
    await verifyProfileCreation(launching);
    console.log(`Chrome ${launching ? "first session and independent drafts" : "profile creation and draft reload while Core is offline"} passed.`);
  } else if (focus === "profile-copy-create" || focus === "profile-copy-launch") {
    const launching = focus === "profile-copy-launch";
    const connection = launching ? "Herdr Core connected" : "Herdr Core disconnected";
    await check(`document.getElementById("core-status").textContent === ${JSON.stringify(connection)} && !document.getElementById("library-open").disabled`);
    await verifyProfileCopy(launching);
    console.log(`Chrome agent copy ${launching ? "launch" : "creation while Core is offline"} passed.`);
  } else if (focus === "profiles-offline") {
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected" && document.getElementById("title").textContent === "Studio Research"');
    await check('document.getElementById("tasks").textContent.includes("task from the new session") && document.getElementById("profile-start").disabled');
    console.log("Chrome offline profile flow passed.");
  } else {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core connected" && !document.getElementById("new").disabled');
  await evaluate('document.getElementById("new").click()');
  if (focus === "runtimes") await pickRuntime();
  await evaluate(`document.getElementById("template").value = ${JSON.stringify(focus === "codex" ? "codex-fixture" : "approval-fixture")};
    document.getElementById("name").value = "browser-test";
    document.getElementById("first-task").value = "browser first task";
    document.getElementById("launch-form").requestSubmit()`);
  await check('document.getElementById("title")?.textContent === "browser-test" && document.getElementById("output").textContent.includes("fixture received: browser first task")');
  if (focus === "codex") {
    await check('document.querySelector("#tasks .reply-item")?.textContent.includes("Codex reply")');
    const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, "-codex.png"), Buffer.from(data, "base64"));
    }
  }
  if (!focus) {
    await evaluate(`document.getElementById("details-toggle").click();
      const task = document.getElementById("task");
      task.value = "browser follow-up";
      task.dispatchEvent(new Event("input"));
      document.getElementById("composer").requestSubmit()`);
    await check('!document.getElementById("details").hidden && document.getElementById("output").textContent.includes("fixture received: browser follow-up")');
    await check('document.getElementById("tasks").textContent.includes("browser follow-up")');
    await check('Array.from(document.querySelectorAll("#tasks .reply-item")).some(node => node.textContent.includes("Structured reply for browser follow-up") && node.textContent.includes("<em>literal text</em>") && !node.querySelector("em"))');
    await evaluate(`const picker = document.getElementById("attachment-picker");
      const data = new DataTransfer();
      data.items.add(new File(["Browser upload bytes"], "browser upload.txt"));
      picker.files = data.files;
      picker.dispatchEvent(new Event("change"))`);
    await check('document.getElementById("direct-draft-files").textContent.includes("browser upload.txt") && !document.getElementById("tasks").textContent.includes("browser upload.txt")');
    await evaluate(`document.getElementById("save-output").click();
      document.getElementById("snapshot-name").value = "Browser result";
      document.getElementById("save-form").requestSubmit()`);
    await check('!document.getElementById("save-dialog").open && document.getElementById("tasks").textContent.includes("Browser result")');
    await cdp("Page.reload");
    await check('document.getElementById("tasks")?.textContent.includes("browser first task") && document.getElementById("tasks").textContent.includes("browser follow-up")');
    await check('document.getElementById("direct-missing-label").textContent.includes("browser upload.txt") && document.getElementById("send").disabled');
    await evaluate('document.getElementById("direct-ignore-missing").click()');
    await evaluate('document.getElementById("library-open").click()');
    await check('document.getElementById("library-items").textContent.includes("Browser result")');
    await evaluate('Array.from(document.querySelectorAll("#library-items button")).find(button => button.textContent.includes("Browser result")).click()');
    await check('document.getElementById("snapshot-title").textContent === "Browser result" && document.getElementById("snapshot-text").textContent.includes("browser follow-up")');
    await evaluate('document.getElementById("library-files").click()');
    await check('document.getElementById("library-items").textContent.includes("Agent result.txt")');
    await evaluate('Array.from(document.querySelectorAll("#library-items button")).find(button => button.textContent.startsWith("Agent result.txt")).click()');
    await check('document.getElementById("file-text").textContent.includes("Generated for browser follow-up") && !document.getElementById("file-text").querySelector("script") && !document.getElementById("file-download").disabled');
    const downloadDir = join(temp, "downloads");
    await cdp("Page.setDownloadBehavior", { behavior: "allow", downloadPath: downloadDir });
    await evaluate('document.getElementById("file-download").click()');
    const downloaded = await waitFor(() => readFile(join(downloadDir, "Agent result.txt"), "utf8").catch(() => ""),
      "Browser did not download the published file");
    assert.equal(downloaded, "Generated for browser follow-up\n<script>plain text</script>");
    const screenshot = process.env.SWARMHUB_TEST_SCREENSHOT;
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, "-library.png"), Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("library-conversations").click()');
    await check('document.getElementById("library-items").textContent.includes("browser-test")');
    await evaluate('Array.from(document.querySelectorAll("#library-items button")).find(button => button.textContent.startsWith("browser-test")).click()');
    await check('document.getElementById("archive-items").textContent.includes("browser follow-up")');
    await check('document.querySelector("#archive-items .reply-item")?.textContent.includes("Claude Code reply")');
    await check('!document.querySelector("#archive-items .remember-task")');
    await evaluate('document.getElementById("library-close").click(); document.getElementById("details-toggle").click()');
    await check('document.getElementById("composer").getBoundingClientRect().bottom <= innerHeight');
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot, Buffer.from(data, "base64"));
    }
    await cdp("Emulation.setDeviceMetricsOverride", { width: 375, height: 812, deviceScaleFactor: 1, mobile: true });
    await check("innerWidth === 375 && document.documentElement.scrollWidth <= innerWidth");
    await evaluate('document.getElementById("close-details").click()');
    await evaluate('document.getElementById("show-agents").click()');
    await check('document.getElementById("agents").getBoundingClientRect().width > 0 && document.getElementById("conversation").getBoundingClientRect().width === 0');
    await evaluate('document.querySelector("#agents [aria-current=true]").click()');
    await check('document.getElementById("task").getBoundingClientRect().width > 0 && document.getElementById("composer").getBoundingClientRect().bottom <= innerHeight');
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, "-mobile.png"), Buffer.from(data, "base64"));
    }
    await cdp("Emulation.clearDeviceMetricsOverride");
    await verifyGroups();
    await evaluate('Array.from(document.querySelectorAll("#agents button")).find(button => button.textContent.includes("browser-test")).click()');
    await check('document.getElementById("composer").getBoundingClientRect().width > 0 && document.getElementById("details-toggle").getBoundingClientRect().width > 0');
    await evaluate('document.getElementById("routines-open").click()');
    await check('!document.getElementById("routine-new").disabled');
    await evaluate(`document.getElementById("routine-new").click();
      document.getElementById("routine-name").value = "Browser check";
      document.getElementById("routine-task").value = "Browser routine task";
      document.getElementById("routine-form").requestSubmit()`);
    await check('document.getElementById("routine-heading").textContent === "Browser check" && document.getElementById("routine-next").textContent.length > 5');
    await evaluate('document.getElementById("routine-toggle").click()');
    await check('document.getElementById("routine-next").textContent === "Paused" && !document.getElementById("routine-test").disabled');
    await evaluate('window.confirm = () => true; document.getElementById("routine-test").click()');
    await check('document.getElementById("routine-runs").textContent.includes("Test · Sent to agent")');
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, "-routine.png"), Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("routine-close").click()');
    await evaluate(`window.deniedAttach = "";
      const invalid = new WebSocket(location.origin.replace(/^http/, "ws") + "/attach/" + idOf(active()));
      invalid.addEventListener("open", () => invalid.send(JSON.stringify({ token: "bad-token", cols: 100, rows: 30 })));
      invalid.addEventListener("message", ({data}) => {window.deniedAttach = typeof data === "string" ? JSON.parse(data).type : "unexpected-output";});
    `);
    await check('window.deniedAttach === "error"');
    await check('!document.getElementById("takeover").hidden');
    await evaluate('document.getElementById("takeover").click()');
    await check('document.getElementById("terminal-status").textContent.startsWith("Attached") && document.getElementById("terminal-host").textContent.includes("fixture received: Browser routine task")');
    const terminalInput = async (text) => {
      await evaluate('document.querySelector("#terminal-host textarea").focus()');
      await check('document.querySelector("#terminal-host textarea") === document.activeElement');
      for (const char of text) {
        const code = char === " " ? "Space" : "Key" + char.toUpperCase();
        const windowsVirtualKeyCode = char.toUpperCase().charCodeAt(0);
        await cdp("Input.dispatchKeyEvent", { type: "keyDown", code, key: char, windowsVirtualKeyCode, text: char });
        await cdp("Input.dispatchKeyEvent", { type: "keyUp", code, key: char, windowsVirtualKeyCode });
      }
      await cdp("Input.dispatchKeyEvent", { type: "keyDown", code: "Enter", key: "Enter", windowsVirtualKeyCode: 13, text: "\r" });
      await cdp("Input.dispatchKeyEvent", { type: "keyUp", code: "Enter", key: "Enter", windowsVirtualKeyCode: 13 });
    };
    await terminalInput("terminal takeover input");
    await check('document.getElementById("terminal-host").textContent.includes("fixture received: terminal takeover input")');
    if (screenshot) {
      const { data } = await cdp("Page.captureScreenshot", { format: "png" });
      await writeFile(screenshot.replace(/\.png$/, "-terminal.png"), Buffer.from(data, "base64"));
    }
    await terminalInput("terminal stream load");
    await check('document.getElementById("terminal-host").textContent.includes("end of large terminal output")');
    await evaluate('document.getElementById("terminal-close").click()');
    await check('!document.getElementById("terminal-dialog").open && !document.getElementById("composer").hidden');
  }
  if (focus === "skills") await verifySkills();
  else if (focus === "groups") await verifyGroups();
  else if (focus === "group-files") { await verifyDirectFileGestures(); await verifyGroups(); await verifyGroupFiles(); }
  else if (focus === "group-results") { await verifyGroups(); await verifyGroupResults(); }
  else if (focus === "group-questions") { await verifyGroups(); await verifyGroupQuestions(); }
  else if (focus === "group-forms") { await verifyGroups(); await verifyGroupForms(); }
  else if (focus === "pages" || focus === "page-tasks") await verifyPages();
  else if (focus === "profiles") await verifyProfiles();
  else if (focus === "instructions") await verifyInstructions();
  else if (focus === "runtimes") {
    await evaluate('document.getElementById("details-toggle").click()');
    await check('document.getElementById("agent-runtime").textContent === "Claude Code" && document.getElementById("agent-provider").textContent === "Fixture Provider" && document.getElementById("agent-model").textContent === "fixture-model"');
    await evaluate('document.getElementById("close-details").click(); document.getElementById("new").click()');
    await evaluate(`const nextTemplate = document.getElementById("template");
      nextTemplate.value = "claude-choice";
      nextTemplate.dispatchEvent(new Event("change"));`);
    await check('!document.getElementById("launch-model-field").hidden && document.getElementById("launch-model").options[0].textContent === "Use Claude Code default" && document.getElementById("load-launch-models").hidden');
    await evaluate(`const model = document.getElementById("launch-model");
      model.value = "sonnet[1m]";
      model.dispatchEvent(new Event("change"));
      document.getElementById("name").value = "claude-picked";
      document.getElementById("first-task").value = "Confirm model selection";`);
    await check('document.getElementById("runtime-labels").textContent === "Claude Code · Anthropic · Fixture Sonnet"');
    if (process.env.SWARMHUB_TEST_SCREENSHOT) {
      const {data} = await cdp("Page.captureScreenshot", {format: "png"});
      await writeFile(process.env.SWARMHUB_TEST_SCREENSHOT.replace(/\.png$/, "-claude-picker.png"), Buffer.from(data, "base64"));
    }
    await evaluate('document.getElementById("launch-form").requestSubmit()');
    await check('document.getElementById("title").textContent === "claude-picked" && document.getElementById("output").textContent.includes("fixture selected model: sonnet[1m]")');
    await check('document.getElementById("agent-model").title === "sonnet[1m]" && document.getElementById("agent-model").textContent === "Fixture Sonnet"');
    await evaluate(`document.getElementById("new").click();
      const runtimeSearch = document.getElementById("runtime-search");
      runtimeSearch.value = "adapter:model-v2";
      runtimeSearch.dispatchEvent(new Event("input"));
      nextTemplate.value = "custom-choice";
      nextTemplate.dispatchEvent(new Event("change"));`);
    await check('document.getElementById("template").options.length === 2 && !document.getElementById("launch-model-field").hidden && document.getElementById("launch-model").options[0].textContent === "Use Custom runner default"');
    await evaluate(`model.value = "local/adapter:model-v2";
      model.dispatchEvent(new Event("change"));
      document.getElementById("name").value = "custom-picked";
      document.getElementById("first-task").value = "Confirm custom model";`);
    await check('document.getElementById("runtime-labels").textContent === "Custom runner · Local endpoint · Adapter v2"');
    await evaluate('document.getElementById("launch-form").requestSubmit()');
    await check('document.getElementById("title").textContent === "custom-picked" && document.getElementById("output").textContent.includes("Custom model: local/adapter:model-v2")');
    await evaluate(`document.getElementById("new").click(); nextTemplate.value = "codex-discovery"; nextTemplate.dispatchEvent(new Event("change"));`);
    await check('!document.getElementById("load-launch-models").hidden && document.getElementById("load-launch-models").textContent === "Load Codex models" && model.options[0].textContent === "Use Codex default" && model.options.length === 2');
    await evaluate('document.getElementById("load-launch-models").click()');
    await check('document.querySelector("#launch-model optgroup")?.label === "Listed by Codex" && [...model.options].some(option => option.value === "provider/gpt-exact") && document.getElementById("launch-model-discovery-status").textContent.includes("does not verify account or provider access")');
    await evaluate(`model.value = "gpt-fixture-listed";
      model.dispatchEvent(new Event("change"));
      document.getElementById("name").value = "codex-discovered";
      document.getElementById("first-task").value = "Use a Codex catalog ID";
      document.getElementById("launch-form").requestSubmit();`);
    await check('document.getElementById("title").textContent === "codex-discovered" && document.getElementById("output").textContent.includes("fixture selected model: gpt-fixture-listed")');
    await evaluate(`document.getElementById("new").click(); nextTemplate.value = "codex-manual"; nextTemplate.dispatchEvent(new Event("change"));`);
    await check('!document.getElementById("launch-model-field").hidden && [...model.options].some(option => option.textContent === "Enter a model ID…") && model.options.length === 2');
    await evaluate(`model.value = [...model.options].find(option => option.textContent === "Enter a model ID…").value;
      model.dispatchEvent(new Event("change"));`);
    await check('!document.getElementById("launch-model-id-field").hidden && document.getElementById("launch-model-id").required');
    await evaluate(`document.getElementById("launch-model-id").value = "gpt-outside-catalog";
      document.getElementById("name").value = "codex-entered";
      document.getElementById("first-task").value = "Use the exact model ID";
      document.getElementById("launch-form").requestSubmit();`);
    await check('document.getElementById("title").textContent === "codex-entered" && document.getElementById("output").textContent.includes("fixture selected model: gpt-outside-catalog")');
    await check('document.getElementById("agent-model").title === "gpt-outside-catalog" && document.getElementById("agent-provider").textContent === "Not specified"');
  }
  else await verifyApproval();
  console.log(focus ? `Chrome ${focus} flow passed.`
    : "Chrome workspace flow passed at desktop and mobile widths.");
  }
} finally {
  ws?.close();
  if (child.exitCode === null && child.signalCode === null && child.pid) {
    const ended = new Promise((resolve) => child.once("close", resolve));
    child.kill();
    await Promise.race([ended, sleep(2000)]);
  }
}
