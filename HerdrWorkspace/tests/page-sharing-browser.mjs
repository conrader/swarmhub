import assert from "node:assert/strict";

export async function verifyPageSharing({origin, token, evaluate, check, cdp, waitFor}) {
  await check('document.getElementById("core-status")?.textContent === "Herdr Core disconnected" && !document.getElementById("library-open").disabled');
  const id = Number(process.env.SWARMHUB_TEST_PAGE);
  assert.ok(Number.isSafeInteger(id) && id > 0);
  await evaluate(`location.hash = "#page=${id}"`);
  await check('document.getElementById("page-heading").textContent === "Field report" && !document.getElementById("page-share").hidden');
  await evaluate('document.getElementById("page-share").click()');
  await check('document.getElementById("page-share-dialog").open && !document.getElementById("page-share-create").disabled && document.getElementById("page-share-mode").value === "fixed"');
  await evaluate(`const shareMode = document.getElementById("page-share-mode");
    shareMode.value = "live"; shareMode.dispatchEvent(new Event("change"));`);
  await check('document.getElementById("page-share-scope").textContent.includes("future edits")');
  await evaluate('document.getElementById("page-share-create").click()');
  const address = await waitFor(() => evaluate('document.getElementById("page-share-url").value'), "Viewer link did not appear.");
  const url = new URL(address);
  assert.equal(url.origin, origin);
  assert.equal(url.pathname, "/view/page");
  assert.match(url.hash, /^#[A-Za-z0-9_-]{43}$/);
  assert.equal(url.search, "");
  assert.notEqual(url.hash.slice(1), token);

  const {targetId} = await cdp("Target.createTarget", {url:"about:blank", background:true});
  const {sessionId} = await cdp("Target.attachToTarget", {targetId, flatten:true});
  try {
    await cdp("Page.navigate", {url:address}, sessionId);
    await cdp("Page.bringToFront", {}, sessionId);
    const viewer = async (expression, message) => waitFor(() => evaluate(expression, sessionId), message);
    await viewer('document.getElementById("shared-title")?.textContent === "Field report" && !document.getElementById("shared-content").hidden', "Viewer did not open without a workspace login.");
    assert.deepEqual(await evaluate(`[sessionStorage.getItem("swarmhub-token"), localStorage.length,
      typeof window.shareExecuted, document.querySelectorAll("article img,article script,article iframe").length,
      document.querySelector("article input[type=checkbox]").disabled]`, sessionId), [null, 0, "undefined", 0, true]);
    await viewer('!!document.querySelector("article svg[role=img]") && document.querySelector("article a").rel === "noopener noreferrer"', "Viewer did not render safe links and charts.");
    await evaluate(`document.querySelector(".page-table-controls").open = true;
      const sharedFilter = document.querySelector(".page-table-controls input");
      sharedFilter.value = "North"; sharedFilter.dispatchEvent(new Event("input"));`, sessionId);
    await viewer('document.querySelectorAll(".page-table-scroll tbody tr:not([hidden])").length === 1', "Read-only viewer table filter did not work.");
    await cdp("Emulation.setDeviceMetricsOverride", {width:390,height:844,deviceScaleFactor:1,mobile:true}, sessionId);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth', sessionId), true);
    const protectedPage = `${origin}/api/pages/${id}`;
    const auth = {Authorization:`Bearer ${token}`, "Content-Type":"application/json", Origin:origin};
    const original = await (await fetch(protectedPage, {headers:auth})).json();
    const updated = await fetch(protectedPage,{method:"POST",headers:auth,body:JSON.stringify({revision:1,title:"Updated field report",
      markdown:original.markdown + "\n\nThe next review is ready."})});
    assert.equal(updated.status, 200);
    await viewer('document.getElementById("shared-title")?.textContent === "Updated field report" && document.getElementById("shared-content").textContent.includes("The next review is ready.")', "The open shared Page did not pick up the later edit.");
    assert.equal(await evaluate('document.querySelector(".page-table-controls input").value', sessionId), "North");
    assert.equal(await evaluate('performance.getEntriesByType("resource").every(({name}) => new URL(name).origin === location.origin && !name.includes(location.hash.slice(1)))', sessionId), true);

    await evaluate(`globalThis.realViewerFetch = window.fetch;
      window.fetch = (url, {signal}) => new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), {once:true});
      });`, sessionId);
    await waitFor(() => evaluate('document.getElementById("shared-content").hidden && !document.getElementById("shared-retry").hidden', sessionId),
      "The viewer kept old Page content when its access check stalled.", 260);
    await evaluate('window.fetch = globalThis.realViewerFetch; document.getElementById("shared-retry").click()', sessionId);
    await viewer('!document.getElementById("shared-content").hidden', "The Page did not return when its connection recovered.");

    await cdp("Page.bringToFront");
    await evaluate('document.getElementById("page-share-revoke").click()');
    await check('document.getElementById("page-share-status").textContent === "Viewer link revoked." && !document.getElementById("page-share-url").value');
    await cdp("Page.bringToFront", {}, sessionId);
    await viewer('document.getElementById("shared-content")?.hidden && document.getElementById("shared-content").textContent === "" && document.getElementById("shared-status").textContent.includes("no longer available")', "The revoked viewer still exposed Page content.");
  } finally {
    await cdp("Target.closeTarget", {targetId});
  }
}
