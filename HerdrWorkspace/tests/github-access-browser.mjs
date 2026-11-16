import assert from "node:assert/strict";

export async function verifyGitHubAccess({ evaluate, check }) {
  const roster = (name) => `[...document.querySelectorAll("#agents button.agent")].find(button => button.textContent.includes(${JSON.stringify(name)}))`;
  const get = (name) => `document.getElementById("agent-github-access-${name}")`;
  const click = (name) => evaluate(`${get(name)}.click()`);
  const owner = roster("github-access-owner"), peer = roster("github-access-peer");
  await check(`${owner} && ${peer} && document.getElementById("core-status").textContent === "Herdr Core connected"`);
  await evaluate(`${owner}.click(); document.getElementById("details-toggle").click()`);
  await check(`!${get("open")}.hidden`);
  await click("open");
  await check(`${get("dialog")}.open && ${get("status")}.textContent === "Read access is off." && ${get("calls")}.children.length === 5`);
  assert.match(await evaluate(`${get("target")}.textContent`), /github-access-owner · fixture\/release-board/);
  const audit = await evaluate(`${get("calls")}.textContent`);
  assert.match(audit, /Issue #98 · Failed or refused/);
  assert.match(audit, /Pull request #12 · Read/);
  assert.doesNotMatch(audit, /Review the café|fixture-only|Delayed private issue/);
  await click("change");
  await check(`${get("change")}.textContent === "Revoke access" && !${get("change")}.disabled`);
  assert.match(await evaluate(`${get("issue")}.textContent`), / github-read issue NUMBER$/);
  assert.match(await evaluate(`${get("pr")}.textContent`), / github-read pr NUMBER$/);
  await click("change");
  await check(`${get("status")}.textContent === "Read access is off." && ${get("help")}.hidden`);
  await evaluate(`${peer}.click()`);
  await check(`!${get("dialog")}.open && !${get("calls")}.textContent`);
  await click("open");
  await check(`${get("dialog")}.open && ${get("empty")}.textContent === "No recent requests for this session."`);
  await click("close");
  await check(`!${get("dialog")}.open`);
}
