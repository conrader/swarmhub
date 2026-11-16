import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

export async function verifyPwa({origin, temp, evaluate, check, cdp}) {
  const secretTask = "Private history for the PWA fixture";
  const secretFile = "Private file for the PWA fixture";
  const draft = "Unsent PWA draft marker";
  const fileId = Number(process.env.SWARMHUB_TEST_PWA_FILE_ID);
  assert.ok(Number.isSafeInteger(fileId) && fileId > 0);

  const browser = async (expression) => {
    const {result, exceptionDetails} = await cdp("Runtime.evaluate", {expression, awaitPromise:true, returnByValue:true});
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description || expression);
    return result.value;
  };
  const network = (offline) => cdp("Network.emulateNetworkConditions", {
    offline, latency:0, downloadThroughput:-1, uploadThroughput:-1,
  });
  async function bridge(available) {
    for (let attempt = 0; attempt < 100; attempt++) {
      const up = await fetch(origin + "/workspace.webmanifest", {cache:"no-store", signal:AbortSignal.timeout(700)})
        .then((response) => response.ok, () => false);
      if (up === available) return;
      await sleep(100);
    }
    assert.fail(`Scratch bridge did not go ${available ? "online" : "offline"}`);
  }

  await check('navigator.serviceWorker.controller?.scriptURL.endsWith("/workspace-sw.js")');
  const manifestReply = await cdp("Page.getAppManifest");
  assert.equal(manifestReply.url, origin + "/workspace.webmanifest");
  assert.deepEqual(manifestReply.errors, []);
  const manifest = JSON.parse(manifestReply.data);
  assert.equal(manifest.id, "/");
  assert.equal(manifest.start_url, "/");
  assert.equal(manifest.scope, "/");
  assert.equal(manifest.display, "standalone");
  assert.deepEqual(manifest.icons.map((icon) => icon.sizes), ["192x192", "512x512"]);
  for (const size of [180, 192, 512]) {
    const info = await browser(`fetch("/pwa/icon-${size}.png").then(async (res) => {
      const icon = await createImageBitmap(await res.blob());
      return [res.headers.get("Content-Type"), icon.width, icon.height];
    })`);
    assert.deepEqual(info, ["image/png", size, size]);
  }
  const install = await cdp("Page.getInstallabilityErrors");
  assert.deepEqual(install.installabilityErrors, []);
  console.log("Chrome reported no PWA installability errors and accepted both manifest icons.");

  await cdp("Emulation.setDeviceMetricsOverride", {width:390, height:844, deviceScaleFactor:2, mobile:true});
  await check('innerWidth === 390');
  await evaluate('document.getElementById("show-agents").click(); document.getElementById("workspace-install-open").click()');
  await check('document.getElementById("workspace-install-dialog").open && document.getElementById("workspace-install-dialog").textContent.includes("Open as Web App") && document.getElementById("workspace-install-dialog").textContent.includes("Android") && document.documentElement.scrollWidth <= innerWidth');
  await evaluate('document.getElementById("workspace-install-close").click()');
  await evaluate('document.querySelector("#agents button.agent").click()');
  await check(`document.getElementById("tasks").textContent.includes(${JSON.stringify(secretTask)})`);
  const file = `/api/library/files/${fileId}/download`;
  const protectedResponse = `fetch(${JSON.stringify(file)}, {headers:{Authorization:"Bearer " + app.token}})`;
  const [policy, text] = await browser(`${protectedResponse}.then(async res => [res.headers.get("Cache-Control"), await res.text()])`);
  assert.equal(policy, "no-store");
  assert.equal(text, secretFile);
  await evaluate(`{ const field = document.getElementById("task"); field.value = ${JSON.stringify(draft)}; field.dispatchEvent(new Event("input")); }`);
  await check(`sessionStorage.getItem("swarmhub-tab-drafts-v1")?.includes(${JSON.stringify(draft)})`);
  assert.deepEqual(await browser('caches.keys()'), []);

  await cdp("Network.enable");
  await network(true);
  try {
    assert.equal(await browser(`${protectedResponse}.then(() => "response", () => "offline")`), "offline");
    assert.equal(await browser('fetch("/api/workspace",{headers:{Authorization:"Bearer " + app.token}}).then(() => "response", () => "offline")'), "offline");
  } finally { await network(false); }

  await evaluate('sessionStorage.removeItem("swarmhub-token"); app.token = "expired-pwa-fixture-token"; void refresh()');
  await check('document.getElementById("core-status").textContent === "Workspace locked" && !sessionStorage.getItem("swarmhub-tab-drafts-v1")');
  assert.equal(await evaluate(`document.body.textContent.includes(${JSON.stringify(secretTask)})`), false);
  assert.deepEqual(await browser('caches.keys()'), []);

  // Stop the scratch Rust bridge. Page-level CDP emulation does not throttle
  // the separate service-worker target on every Chrome build.
  await writeFile(join(temp, "pwa-go-offline"), "");
  await bridge(false);
  const navigation = await cdp("Page.navigate", {url: origin + "/?pwa-test=offline"});
  assert.ok(!navigation.errorText, navigation.errorText);
  await check('document.querySelector("h1")?.textContent === "Workspace unreachable"');
  const body = await evaluate('document.body.textContent');
  for (const value of [secretTask, secretFile, draft]) assert.ok(!body.includes(value));
  assert.equal(await evaluate('document.querySelectorAll("script").length'), 0);
  assert.deepEqual(await browser('caches.keys()'), []);
  await cdp("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:"light"}]});
  await check('getComputedStyle(document.documentElement).backgroundColor === "rgb(244, 245, 250)"');
  await cdp("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value:"dark"}]});
  await check('getComputedStyle(document.documentElement).backgroundColor === "rgb(22, 24, 30)"');
  await writeFile(join(temp, "pwa-go-online"), "");
  await bridge(true);
  await cdp("Page.navigate", {url: origin});
  await check('document.getElementById("core-status")?.textContent === "Workspace locked"');
  console.log("Mobile viewport, live authorization, private files, zero Cache Storage, and the generic offline screen passed.");
}
