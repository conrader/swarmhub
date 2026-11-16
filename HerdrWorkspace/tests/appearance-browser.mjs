import assert from "node:assert/strict";

function luminance(color) {
  const rgb = color.match(/\d+(?:\.\d+)?/g).slice(0, 3).map((value) => Number(value) / 255)
    .map((value) => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
  return .2126 * rgb[0] + .7152 * rgb[1] + .0722 * rgb[2];
}

export async function verifyAppearance({evaluate, check, cdp}) {
  const storageKey = "swarmhub-appearance-v1";
  const selector = 'document.querySelector("#appearance-form :checked")';
  const displayed = 'document.documentElement.dataset.appearance';
  const unlocked = 'document.getElementById("core-status")?.textContent === "Herdr Core connected"';
  const click = (id) => evaluate(`document.getElementById(${JSON.stringify(id)}).click()`);
  const theme = (value) => cdp("Emulation.setEmulatedMedia", {features:[{name:"prefers-color-scheme",value}]});
  const key = async (name, windowsVirtualKeyCode) => {
    const input = {key:name, code:name, windowsVirtualKeyCode};
    await cdp("Input.dispatchKeyEvent", {...input,type:"keyDown", ...(name === "Enter" ? {text:"\r"} : {})});
    await cdp("Input.dispatchKeyEvent", {...input,type:"keyUp"});
  };
  const expected = (mode) => check(`${displayed} === ${JSON.stringify(mode)} && getComputedStyle(document.documentElement).colorScheme === ${JSON.stringify(mode)}`);
  async function contrast(mode) {
    const pairs = [
      ["main text", "body", "color", "body"],
      ["muted roster text", ".brand small", "color", ".sidebar"],
      ["selected roster text", "#agents button.agent[aria-current='true']", "color", "#agents button.agent[aria-current='true']"],
      ["primary button", "#profile-new", "color", "#profile-new"],
      ["brand icon", ".mark", "color", ".mark"],
      ["chat label", "#tasks .task-item strong", "color", "#tasks .task-item"],
      ["composer text", "#task", "color", "#composer"],
      ["composer placeholder", "#task", "color", "#composer", "::placeholder"],
      ["dialog copy", "#appearance-dialog p", "color", "#appearance-dialog"],
      ["dialog radio label", "#appearance-form label:has(:checked)", "color", "#appearance-form label:has(:checked)"],
      ["details label", "#details dt", "color", "#details"],
      ["danger action", "#end", "color", "#end"],
    ];
    const actual = await evaluate(`${JSON.stringify(pairs)}.map(([name, selector, property, surface, pseudo]) => {
      const foreground = getComputedStyle(document.querySelector(selector), pseudo || null)[property];
      const background = getComputedStyle(document.querySelector(surface)).backgroundColor;
      return [name, foreground, background];
    })`);
    let weakest = Infinity;
    for (const [name, foreground, background] of actual) {
      const a = luminance(foreground), b = luminance(background);
      const ratio = (Math.max(a,b) + .05) / (Math.min(a,b) + .05);
      weakest = Math.min(weakest, ratio);
      assert.ok(ratio >= 4.5, `${mode} ${name}: ${ratio.toFixed(2)}:1 (${foreground}, ${background})`);
    }
    if (mode === "light") {
      const extra = await evaluate(`[getComputedStyle(${selector}).outlineColor,
        getComputedStyle(document.querySelector("#appearance-dialog")).backgroundColor,
        getComputedStyle(document.querySelector("#appearance-form label:not(:has(:checked))")).borderTopColor]`);
      for (const ink of [extra[0], extra[2]]) {
        const a = luminance(ink), b = luminance(extra[1]);
        assert.ok((Math.max(a,b) + .05) / (Math.min(a,b) + .05) >= 3);
      }
    }
    return weakest;
  }

  await check(`${unlocked} && document.querySelector("#tasks .task-item strong") && document.querySelector("#agents :is(.agent)[aria-current='true']")`);
  await theme("dark");
  await expected("dark");
  assert.equal(await evaluate(`localStorage.getItem(${JSON.stringify(storageKey)})`), null);

  await evaluate('document.getElementById("appearance-open").focus()');
  await key("Enter",13);
  await check(`document.getElementById("appearance-dialog").open && document.activeElement === ${selector} && ${selector}.value === "system"`);
  const dark = await contrast("dark");
  await key("ArrowDown",40);
  await expected("light");
  await check(`${selector}.value === "light" && ${selector}.matches(":focus-visible") && getComputedStyle(${selector}).outlineWidth === "2px"`);
  const light = await contrast("light");
  assert.equal(await evaluate('document.querySelector(\'meta[name="theme-color"]\').content'), "#f4f5fa");
  assert.ok((await evaluate('getComputedStyle(document.getElementById("appearance-dialog"), "::backdrop").backgroundColor')).startsWith("rgba(37, 40, 67"));
  await key("Escape",27);
  await check('!document.getElementById("appearance-dialog").open && document.activeElement.id === "appearance-open"');

  await cdp("Page.enable");
  await cdp("Page.addScriptToEvaluateOnNewDocument", {source:`
    new PerformanceObserver((events) => {
      if (!events.getEntries().some((entry) => entry.name === "first-contentful-paint")) return;
      window.appearanceFirstPaint = [document.documentElement.dataset.appearance, getComputedStyle(document.body).backgroundColor];
    }).observe({type:"paint", buffered:true});
  `});
  await cdp("Page.reload", {ignoreCache:true});
  await check(unlocked);
  await expected("light");
  await check('!!window.appearanceFirstPaint');
  assert.deepEqual(await evaluate('window.appearanceFirstPaint'), ["light","rgb(244, 245, 250)"]);
  assert.equal(await evaluate(`localStorage.getItem(${JSON.stringify(storageKey)})`), "light");

  await click("appearance-open");
  await key("ArrowUp",38);
  await expected("dark");
  await theme("light");
  await expected("light");
  await check('document.getElementById("appearance-status").textContent.includes("(light)")');
  await theme("dark");
  await expected("dark");
  await key("ArrowUp",38); // Native radio group wraps System → Dark.
  await check(`${selector}.value === "dark"`);
  await theme("light");
  await expected("dark");
  await key("ArrowDown",40);
  await expected("light");
  assert.equal(await evaluate(`localStorage.getItem(${JSON.stringify(storageKey)})`), "system");
  await key("Escape",27);

  await cdp("Emulation.setDeviceMetricsOverride", {width:390, height:844, deviceScaleFactor:2, mobile:true});
  await click("show-agents");
  await click("appearance-open");
  await check('innerWidth === 390 && document.documentElement.scrollWidth <= innerWidth && document.getElementById("appearance-dialog").open && document.getElementById("appearance-dialog").getBoundingClientRect().right <= innerWidth && document.querySelector("#appearance-form label").getBoundingClientRect().height >= 44');
  await key("Escape",27);
  await evaluate('document.querySelector("#agents button.agent").click()');
  await click("details-toggle");
  await check('!document.getElementById("details").hidden && getComputedStyle(document.getElementById("details")).boxShadow.includes("rgba(37, 40, 67")');
  console.log(`Chrome verified desktop and 390px Appearance, keyboard controls, reload/first paint, System updates; weakest tested text contrast Light ${light.toFixed(2)}:1 / Dark ${dark.toFixed(2)}:1.`);
}
