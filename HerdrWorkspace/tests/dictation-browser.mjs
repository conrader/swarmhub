function installFixture() {
  const fake = window.localDictationFixture = {
    availability:"downloadable", checks:[], installs:[], starts:[], aborts:0, stops:0, acceptsLocal:true, listening:null,
    result(text, isFinal) {
      const event = new Event("result");
      event.results = [Object.assign([{transcript:text}], {isFinal})];
      this.listening.dispatchEvent(event);
    },
  };
  const requireLocal = (options) => {
    if (options.processLocally !== true || options.quality !== "dictation" || options.langs.length !== 1) {
      throw new Error("Expected a single-language, on-device dictation request");
    }
  };
  class Recognition extends EventTarget {
    static async available(options) { requireLocal(options); fake.checks.push(options); return fake.availability; }
    static async install(options) {
      requireLocal(options);
      fake.installs.push(options);
      fake.availability = "available";
      return true;
    }
    get processLocally() { return this.local; }
    set processLocally(value) { this.local = fake.acceptsLocal && value === true; }
    start() {
      fake.starts.push({lang:this.lang, local:this.processLocally, interim:this.interimResults, continuous:this.continuous});
      if (this.processLocally !== true) throw new Error("A remote recognition was attempted");
      fake.listening = this;
      this.dispatchEvent(new Event("start"));
    }
    stop() {
      fake.stops++;
      queueMicrotask(() => {
        if (fake.listening !== this) return;
        fake.result("Final on-device transcript", true);
        fake.listening = null;
        this.dispatchEvent(new Event("end"));
      });
    }
    abort() {
      fake.aborts++;
      if (fake.listening === this) fake.listening = null;
      this.dispatchEvent(new Event("end"));
    }
  }
  Object.defineProperty(window, "SpeechRecognition", {value:Recognition, configurable:true});
}

export async function verifyDictation({evaluate, check}) {
  const element = (id) => `document.getElementById("dictation-${id}")`;
  const click = (id) => evaluate(element(id) + ".click()");
  const close = () => click("close");
  const set = (field, value) => evaluate(`{ const field = document.getElementById(${JSON.stringify(field)}); field.value = ${JSON.stringify(value)}; field.dispatchEvent(new Event("input")); }`);
  const equals = (field, value) => `document.getElementById(${JSON.stringify(field)}).value === ${JSON.stringify(value)}`;
  const direct = '[...document.querySelectorAll("#agents button.agent")].find((item) => item.textContent.includes("dictation-direct"))';
  const group = '[...document.querySelectorAll("#groups button")].find((item) => item.textContent.includes("Dictation group"))';
  await check(`!!${direct} && !!${group}`);
  await evaluate(direct + ".click()");
  await check('!document.getElementById("dictate-direct").disabled');

  // This report uses the actual browser implementation. Never install or record with it.
  await evaluate('document.getElementById("dictate-direct").click()');
  await check(`${element("status")}.textContent.trim() && !${element("status")}.textContent.startsWith("Checking")`);
  const native = await evaluate(`[navigator.userAgent.split(" ").find((part) => part.includes("Chrome/")), navigator.language, ${element("status")}.textContent]`);
  console.log("Native browser dictation availability (no pack installed or audio captured):", native.join(" · "));
  await close();
  await evaluate(`(${installFixture})()`);

  await set("task", "Original direct draft");
  await evaluate('document.getElementById("dictate-direct").click()');
  await check(`!${element("prepare")}.hidden && ${element("start")}.hidden && localDictationFixture.installs.length === 0 && localDictationFixture.starts.length === 0`);
  await set("dictation-language", "pl-PL");
  await click("check");
  await check(`localDictationFixture.checks.at(-1).langs[0] === "pl-PL" && !${element("prepare")}.disabled`);
  await click("prepare");
  await check(`localDictationFixture.installs.length === 1 && localDictationFixture.installs[0].langs[0] === "pl-PL" && !${element("start")}.hidden && localDictationFixture.starts.length === 0`);
  await click("start");
  await check('localDictationFixture.listening && localDictationFixture.starts[0].lang === "pl-PL" && localDictationFixture.starts[0].local && localDictationFixture.starts[0].interim && localDictationFixture.starts[0].continuous');
  await evaluate('localDictationFixture.result("Tentative suggestion", false)');
  await check(`${element("text")}.value === "Tentative suggestion" && ${element("text")}.readOnly && ${element("add")}.hidden && document.getElementById("task").value === "Original direct draft"`);
  await click("stop");
  await check(`${element("text")}.value === "Final on-device transcript" && !${element("text")}.readOnly && !localDictationFixture.listening`);
  await set("dictation-text", "Reviewed direct text");
  await click("add");
  await check(`!${element("dialog")}.open && ${equals("task", "Original direct draft\n\nReviewed direct text")}`);

  await evaluate('localDictationFixture.availability = "unavailable"; document.getElementById("dictate-direct").click()');
  await check(`${element("status")}.textContent.includes("unavailable for this language") && ${element("start")}.hidden && ${element("prepare")}.hidden`);
  await close();
  await evaluate('localDictationFixture.availability = "available"; localDictationFixture.acceptsLocal = false; document.getElementById("dictate-direct").click()');
  await check(`!${element("start")}.hidden`);
  await click("start");
  await check(`${element("error")}.textContent.includes("No remote recognition was requested") && localDictationFixture.starts.length === 1`);
  await close();

  await evaluate('localDictationFixture.acceptsLocal = true; document.getElementById("dictate-direct").click()');
  await check(`!${element("start")}.hidden`);
  await click("start");
  await evaluate(group + ".click()");
  await check(`!${element("dialog")}.open && !localDictationFixture.listening && localDictationFixture.aborts === 1`);

  await set("group-task", "Original group draft");
  await evaluate('document.getElementById("dictate-group").click()');
  await check(`!${element("start")}.hidden`);
  await click("start");
  await click("stop");
  await check(`!${element("text")}.readOnly && !${element("add")}.disabled`);
  await set("dictation-text", "x".repeat(8192));
  await click("add");
  await check(`${element("error")}.textContent.includes("8 KiB") && document.getElementById("group-task").value === "Original group draft"`);
  await set("dictation-text", "Reviewed group text");
  await click("add");
  await check(`!${element("dialog")}.open && ${equals("group-task", "Original group draft\n\nReviewed group text")}`);

  await evaluate(direct + ".click()");
  await check(equals("task", "Original direct draft\n\nReviewed direct text"));
  await evaluate('document.getElementById("dictate-direct").click()');
  await check(`!${element("start")}.hidden`);
  await click("start");
  await evaluate('app.token = "invalid-dictation-fixture-token"; void refresh()');
  await check(`!${element("dialog")}.open && localDictationFixture.aborts === 2 && !localDictationFixture.listening && document.getElementById("core-status").textContent === "Workspace locked"`);
}
