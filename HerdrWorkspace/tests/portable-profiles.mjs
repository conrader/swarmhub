import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";

const [bridge, chrome] = process.argv.slice(2);
const root = await mkdtemp(join(tmpdir(), "swarmhub-template-"));
const token = randomBytes(32).toString("hex");
const format = "swarmhub-agent-template/v1";
const launched = spawn(bridge, [], {env: {
  HC_SOCKET: join(root, "no-core.sock"), SWARMHUB_DATA_DIR: join(root, "workspace"),
  SWARMHUB_PORT: "0", SWARMHUB_ACCESS_TOKEN: token,
}, stdio: ["ignore", "pipe", "inherit"]});
let origin;

async function stop(child) {
  if (child?.exitCode === null && child.signalCode === null) {
    child.kill();
    await once(child, "exit");
  }
}

async function request(path, body, status = 200, auth = true, from = origin) {
  const headers = auth ? {Authorization: "Bearer " + token} : {};
  const isPost = body !== undefined;
  if (isPost) Object.assign(headers, {Origin: from, "Content-Type": "application/json"});
  const response = await fetch(origin + path, {headers, method: isPost ? "POST" : "GET",
    body: isPost ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined});
  const raw = await response.text();
  assert.equal(response.status, status, `${path}: ${raw}`);
  return response.headers.get("content-type")?.includes("application/json") ? JSON.parse(raw) : raw;
}

async function until(condition, description) {
  for (let i = 0; i < 150; ++i) {
    const value = await condition();
    if (value) return value;
    await sleep(100);
  }
  throw new Error("Timed out: " + description);
}

async function verifyChrome(profile, originalTemplate) {
  const chromeProfile = join(root, "chrome");
  const downloads = join(root, "downloads");
  await mkdir(downloads);
  const child = spawn(chrome, ["--headless", "--no-sandbox", "--disable-gpu", "--disable-background-networking",
    "--remote-debugging-port=0", "--window-size=1280,900", "--no-first-run", "--no-default-browser-check",
    "--no-proxy-server", `--user-data-dir=${chromeProfile}`, "about:blank"],
  {env: {PATH: process.env.PATH, HOME: root, DBUS_SESSION_BUS_ADDRESS: `unix:path=${join(root, "no-dbus")}`},
    stdio: ["ignore", "ignore", "ignore"]});
  const pending = new Map();
  const browserErrors = [];
  let ws, next = 0;
  let evaluate;
  try {
    const port = await until(async () => {
      if (child.exitCode !== null) throw new Error("Chrome did not start");
      return parseInt(await readFile(join(chromeProfile, "DevToolsActivePort"), "utf8").catch(() => ""), 10);
    }, "Chrome debugger port");
    const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((target) => target.type === "page");
    assert.ok(page);
    ws = new WebSocket(page.webSocketDebuggerUrl);
    ws.addEventListener("message", ({data}) => {
      const {id, error, result, method, params} = JSON.parse(data);
      if (method === "Runtime.exceptionThrown" && browserErrors.length < 10) {
        browserErrors.push(params.exceptionDetails.exception?.description || params.exceptionDetails.text);
      }
      const sent = pending.get(id);
      if (!sent) return;
      pending.delete(id);
      if (error) sent.reject(new Error(error.message));
      else sent.resolve(result);
    });
    await Promise.race([once(ws, "open"), once(ws, "error").then(() => {throw new Error("Chrome debugger failed");})]);
    const cdp = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, {resolve, reject});
      ws.send(JSON.stringify({id, method, params}));
    });
    evaluate = async (expression) => {
      const {result, exceptionDetails} = await cdp("Runtime.evaluate", {expression, returnByValue: true, userGesture: true});
      if (exceptionDetails) throw new Error(exceptionDetails.exception?.description || expression);
      return result.value;
    };
    const check = (expression) => until(() => evaluate(expression), expression);
    const click = (id) => evaluate(`document.getElementById(${JSON.stringify(id)}).click()`);
    await cdp("Page.setDownloadBehavior", {behavior: "allow", downloadPath: downloads});
    await cdp("Runtime.enable");
    await cdp("Page.navigate", {url: origin});
    await check('document.getElementById("core-status")?.textContent === "Workspace locked"');
    assert.equal(await evaluate('document.getElementById("profile-template-import").disabled'), true);
    await evaluate(`document.getElementById("unlock").click(); document.getElementById("token").value = ${JSON.stringify(token)};
      document.getElementById("access-form").requestSubmit()`);
    await check('document.getElementById("core-status").textContent === "Herdr Core disconnected"');
    await check(`!!document.querySelector('[data-key="profile:${profile.id}"]')`);
    await evaluate(`document.querySelector('[data-key="profile:${profile.id}"]').click()`);
    await click("details-toggle");
    await click("profile-template-export");
    await check('!document.getElementById("profile-template-save").disabled');
    assert.equal(await evaluate('document.getElementById("profile-template-instructions").value'), originalTemplate.instructions);
    const instructions = "Review the weekly report.";
    await evaluate(`document.getElementById("profile-template-instructions").value = ${JSON.stringify(instructions)};`);
    await click("profile-template-save");
    const downloaded = join(downloads, "portable-agent.swarmhub-agent.json");
    const json = await until(() => readFile(downloaded, "utf8").catch(() => ""), "template download");
    assert.deepEqual(JSON.parse(json), {...originalTemplate, instructions});
    assert.deepEqual(await request(`/api/profiles/${profile.id}/agent-template`), originalTemplate);
    await click("profile-template-close");
    await click("profile-template-import");
    const wrong = join(root, "wrong.json");
    await writeFile(wrong, '{"format":"other"}');
    const {root: dom} = await cdp("DOM.getDocument");
    const {nodeId} = await cdp("DOM.querySelector", {nodeId: dom.nodeId, selector: "#profile-template-file"});
    const choose = (path) => cdp("DOM.setFileInputFiles", {nodeId, files: [path]});
    await choose(wrong);
    await check('document.getElementById("profile-template-error").textContent.includes("supported v1")');
    await choose(downloaded);
    await check('document.activeElement.id === "profile-template-name" && !document.getElementById("profile-template-save").disabled');
    assert.equal(await evaluate('document.getElementById("profile-template-instructions").value'), instructions);
    const count = (await request("/api/profiles")).length;
    await click("profile-template-close");
    assert.equal((await request("/api/profiles")).length, count);
    await click("profile-template-import");
    await choose(downloaded);
    await check('!document.getElementById("profile-template-save").disabled');
    await evaluate('document.getElementById("profile-template-name").value = "Reviewed offline"');
    await click("profile-template-save");
    await check('document.getElementById("title").textContent === "Reviewed offline" && !document.getElementById("profile-template-dialog").open');
    const fresh = (await request("/api/profiles")).find(({name}) => name === "Reviewed offline");
    assert.equal(fresh.instructions, instructions);
    assert.deepEqual(fresh.sessions, []);
    assert.equal(fresh.copied_setup, undefined);
    console.log("Chrome verified template preview, redaction, download, cancellation, and offline import.");
  } catch (error) {
    if (evaluate && ws?.readyState === WebSocket.OPEN) {
      console.error(await evaluate('[location.href, document.getElementById("core-status")?.textContent, document.getElementById("profile-template-error")?.textContent]').catch(() => null));
      if (browserErrors.length) console.error(browserErrors);
    }
    throw error;
  } finally {
    ws?.close();
    await stop(child);
  }
}

try {
  const output = createInterface({input: launched.stdout});
  const [line] = await once(output, "line");
  origin = line.match(/^SwarmHub · (http:\/\/127\.0\.0\.1:\d+)$/)?.[1];
  assert.ok(origin, line);
  await request("/api/profile-templates/preview", {}, 401, false);
  await request("/api/profile-templates/import", {}, 403, true, "https://foreign.example");
  const original = await request("/api/profiles", {name: "Portable agent"}, 201);
  const template = {format, name: original.name, subtitle: "Product research", avatar: "layers",
    instructions: "<img src=x onerror=alert(1)>\nPrivate note"};
  await request(`/api/profiles/${original.id}`, {...template, format: undefined, pinned: true,
    hidden: false, revision: original.revision});
  const url = `/api/profiles/${original.id}/agent-template`;
  await request(url, undefined, 401, false);
  assert.deepEqual(await request(url), template);
  for (const payload of [{...template, token: "test-token"}, {...template, routines: []},
    {...template, avatar: "image"}, {...template, format: "swarmhub-agent-template/v2"},
    {...template, instructions: "x".repeat(6145)}, JSON.stringify(template).replace('{', '{"name":"duplicate",')]) {
    await request("/api/profile-templates/import", payload, 422);
  }
  await request("/api/profile-templates/import", " ".repeat(48 * 1024 + 1), 413);
  const edited = {...template, name: "  New offline profile  ", instructions: "First line.\r\nSecond line."};
  const preview = await request("/api/profile-templates/preview", edited);
  assert.equal(preview.name, "New offline profile");
  assert.equal(preview.instructions, "First line.\nSecond line.");
  assert.equal((await request("/api/profiles")).length, 1);
  const imported = await request("/api/profile-templates/import", preview, 201);
  assert.notEqual(imported.id, original.id);
  assert.notEqual(imported.runtime_name, original.runtime_name);
  assert.equal(imported.pinned, false);
  assert.equal(imported.section_id, null);
  assert.equal(imported.copied_setup, undefined);
  assert.deepEqual(imported.sessions, []);
  assert.deepEqual(await request(`/api/profiles/${imported.id}/agent-template`), preview);
  console.log("API verified strict template validation, read-only preview, and a fresh offline profile.");
  if (chrome) await verifyChrome(original, template);
} finally {
  await stop(launched);
  await rm(root, {recursive: true, force: true});
}
