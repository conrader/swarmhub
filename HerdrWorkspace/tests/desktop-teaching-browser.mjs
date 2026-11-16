import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

export async function verifyDesktopTeaching({evaluate, check, cdp, temp}) {
  const el = (id) => `document.getElementById(${JSON.stringify(id)})`;
  const action = (id) => evaluate(el(id) + ".click()");
  const teaching = (id) => action("desktop-teach-" + id);
  const center = 'document.querySelector("#desktop-screen canvas")';
  const steps = 'document.querySelectorAll("#desktop-teach-steps li")';
  const status = el("desktop-teach-status") + ".textContent";
  const log = async () => (await readFile(join(temp,"desktop-clicks.log"), "utf8")).trim().split("\n");
  async function openDesktop() {
    await check(`!${el("desktop-open")}.hidden`);
    await action("desktop-open");
    await check(`${el("desktop-status")}.textContent.startsWith("Watching") && ${center}?.width === 1280`);
    await check(`${el("desktop-teaching")}.hidden`);
    await action("desktop-control");
    await check(`${el("desktop-status")}.textContent.startsWith("You have control") && !${el("desktop-teaching")}.hidden`);
  }
  async function mouse(u, v, button = "left", drag = false) {
    const [x,y] = await evaluate(`(() => { const frame = ${center}.getBoundingClientRect(); return [Math.floor(frame.x + frame.width * ${u}), Math.floor(frame.y + frame.height * ${v})]; })()`);
    await cdp("Input.dispatchMouseEvent", {type:"mousePressed", x, y, button, buttons:{left:1, right:2, middle:4}[button], clickCount:1});
    if (drag) await cdp("Input.dispatchMouseEvent", {type:"mouseMoved", x:x + 28, y, buttons:1});
    await cdp("Input.dispatchMouseEvent", {type:"mouseReleased", x:drag ? x + 28 : x, y, button, buttons:0, clickCount:1});
  }
  async function start(goal) {
    await teaching("open");
    if (goal) await evaluate(`${el("desktop-teach-goal")}.value = ${JSON.stringify(goal)}`);
    await teaching("start");
    await check(`${status}.startsWith("Recording clicks")`);
  }
  async function eventLog(predicate) {
    for (let i = 0; i < 50; i++) {
      const current = await log();
      if (predicate(current)) return current;
      await sleep(100);
    }
    throw new Error("The scratch X11 application did not receive the expected input.");
  }

  await check(`${el("title")}.textContent === "teaching-fixture"`);
  await action("details-toggle");
  await openDesktop();

  await start("Discard this sample");
  await mouse(.45, .45);
  await check(`${status}.includes("1 of 24")`);
  for (let i = 0; i < 23; i++) await mouse(.34 + (i % 6) * .015, .42);
  await check(`${steps}.length === 24 && ${status}.includes("24-click limit")`);
  await eventLog((rows) => rows.filter((row) => row.startsWith("click 1 ")).length === 24);
  await action("desktop-watch");
  await check(`${el("desktop-status")}.textContent.startsWith("Watching") && ${el("desktop-teaching")}.hidden && !${el("desktop-teach-goal")}.value`);
  await action("desktop-control");
  await check(`!${el("desktop-teaching")}.hidden`);
  const original = (await log()).length;

  await start("Open the weekly report");
  await mouse(.30, .32);
  await check(`${status}.includes("1 of 24")`);
  await evaluate(`{const canvas = ${center}; const rect = canvas.getBoundingClientRect();
    for (const type of ["pointerdown","pointerup"]) canvas.dispatchEvent(new PointerEvent(type,{pointerType:"mouse",pointerId:8,button:0,clientX:rect.x+25,clientY:rect.y+25,bubbles:true})); }`);
  await cdp("Input.dispatchKeyEvent", {type:"keyDown", key:"a", code:"KeyA", text:"a", windowsVirtualKeyCode:65});
  await cdp("Input.dispatchKeyEvent", {type:"keyUp", key:"a", code:"KeyA", windowsVirtualKeyCode:65});
  await mouse(.62,.52,"right");
  await check(`${status}.includes("2 of 24")`);
  await mouse(.4,.4,"left",true);
  await teaching("stop");
  await check(`${steps}.length === 2 && !${el("desktop-teach-review")}.hidden`);
  const delivered = (await eventLog((rows) => rows.slice(original).filter((row) => row.startsWith("click")).length >= 3 && rows.includes("key"))).slice(original);
  const coordinates = await evaluate(`[...${steps}].map((row) => row.querySelector("label").textContent.split("(")[1].split(")")[0].split(", ").map(Number))`);
  assert.equal(delivered[0].split(" ")[1], "1");
  assert.equal(delivered.find((row) => row.startsWith("click 3 ")).split(" ")[1], "3");
  for (const [index, button] of [[0,1],[1,3]]) {
    const x11 = delivered.find((row) => row.startsWith(`click ${button} `)).split(" ").slice(2).map(Number);
    assert.ok(x11.every((coordinate, dimension) => Math.abs(coordinate - coordinates[index][dimension]) <= 3), [x11, coordinates[index]]);
  }

  await evaluate(`${el("desktop-teach-label-0")}.value = "Open the report menu"; ${el("desktop-teach-label-0")}.dispatchEvent(new Event("input")); document.querySelector('[aria-label="Remove step 2"]').click()`);
  await teaching("skill");
  await check(`${el("skill-dialog")}.open && ${el("skill-heading")}.textContent === "Review demonstrated skill" && !${el("desktop-dialog")}.open`);
  await check(`${el("skill-text")}.value.includes("Open the weekly report") && ${el("skill-text")}.value.includes("Open the report menu") && !${el("skill-text")}.value.includes("Right click")`);
  await evaluate(`${el("skill-name")}.value = "Weekly menu demonstration"; ${el("skill-form")}.requestSubmit()`);
  await check(`${el("skill-version")}.textContent === "Version 1"`);
  await action("skill-close");
  assert.equal((await log()).length, original + delivered.length, "Saving must not replay user input");

  await openDesktop();
  await start("Do not retain this draft");
  await mouse(.35,.40);
  await check(`${status}.includes("1 of 24")`);
  await teaching("stop");
  await teaching("skill");
  await check(`${el("skill-dialog")}.open`);
  await evaluate('app.token = "invalid-teaching-test-token"; void refresh()');
  await check(`${el("core-status")}.textContent === "Workspace locked" && !${el("skill-dialog")}.open && !${el("skill-text")}.value && ${steps}.length === 0`);
}
