import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const parked = "/api/parks/outbound-fixture";
const draft = "/api/history/core/t1/17/email-drafts/42";

test("the email editor stages every field, then opens the immutable signed approval preview", async () => {
  const elements = new Map();
  const created = [];
  const get = (id) => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  class Element {
    children = [];
    listeners = {};
    dataset = {};
    value = "";
    hidden = false;
    open = false;
    set textContent(text) { this.firstChild = {textContent: text}; }
    get textContent() { return this.firstChild?.textContent ?? ""; }
    set innerHTML(html) {
      for (const [, id] of html.matchAll(/id="([^"]+)"/g)) get(id);
    }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; }
    setAttribute() {}
    focus() {}
    after() {}
    showModal() { this.open = true; }
    close() { this.open = false; void this.fire("close"); }
    addEventListener(name, listener) { this.listeners[name] = listener; }
    fire(name) { return this.listeners[name]?.({preventDefault() {}}); }
  }
  const payload = {
    channel: "email", sender: "sender@example.test", to: ["reviewer@example.test"],
    cc: ["cc@example.test"], bcc: ["bcc@example.test"], subject: "Draft",
    in_reply_to: "<msg@example.test>", thread_id: "thread-1", body: "Café\n<script>copy</script>",
  };
  const decision = {
    envelope: {purpose: "authorize_outbound", target: {park: {id: "outbound-fixture", manifest_digest: "a".repeat(64)}}},
    signature: "fixture-signature",
  };
  const park = {id: decision.envelope.target.park.id, manifest_digest: decision.envelope.target.park.manifest_digest};
  let approved = false;
  const calls = [];
  const browser = {
    TextEncoder,
    document: {
      body: new Element(),
      createElement(tag) {
        const node = new Element();
        created.push({tag, node});
        return node;
      },
      querySelectorAll: () => [],
    },
    window: {},
    $: get,
    app: {authorized: true, token: "fixture"},
    setInterval() {},
    show(id, text) { get(id).textContent = text; },
    async api(path, body) {
      calls.push(path);
      if (path === draft) return {
        state: "reviewed", revision: 2, draft: {to: "reviewer@example.test", subject: "Draft", body: payload.body},
      };
      const version = {version: 1, park, in_flight: [], payload, state: "pending", approval: approved ? decision : null};
      if (path === draft + "/stage") {
        const {channel, ...email} = payload;
        assert.deepEqual(JSON.parse(JSON.stringify(body)), {revision: 2, version: 0, email});
        return version;
      }
      if (path === parked) return {
        detail: {view: {status: "pending"}, manifest: {artifact_pin: "pinned"}},
        pin: decision.envelope.target.park,
        classification: {class: "outside_message"},
        outbound: {version, sending_enabled: false, text_review: null},
      };
      if (path === "/api/parks/decide") {
        assert.deepEqual(JSON.parse(JSON.stringify(body)), {park, purpose: "authorize_outbound", evidence: {signed: decision}});
        approved = true;
        return {result: "outbound_approved"};
      }
      assert.fail("Unexpected workspace API call " + path);
    },
  };
  for (const file of ["approvals.js", "email-drafts.js"]) {
    runInNewContext(readFileSync(new URL("../web/" + file, import.meta.url), "utf8"), browser);
  }
  await browser.window.workspaceEmailDrafts.open(draft);
  for (const [field, value] of Object.entries({
    sender: payload.sender, cc: payload.cc[0], bcc: payload.bcc[0],
    reply: payload.in_reply_to, thread: payload.thread_id,
  })) get("email-draft-" + field).value = value;
  await get("email-draft-stage").fire("click");
  assert.match(get("email-draft-status").textContent, /Revision 1 · Awaiting signed decision/);
  assert.equal(get("email-draft-preview").hidden, false);
  get("email-draft-preview").fire("click");
  await new Promise(setImmediate);
  const preview = created.find(({tag}) => tag === "pre").node;
  assert.deepEqual(JSON.parse(preview.textContent).outbound.version.payload, payload);
  const approvalForm = created.find(({tag}) => tag === "form").node;
  const signature = created.find(({tag}) => tag === "textarea").node;
  signature.value = JSON.stringify(decision);
  await approvalForm.fire("submit");
  assert.equal(get("approval-notice").textContent, "Signed decision recorded. Sending is disabled.");
  assert.equal(JSON.parse(preview.textContent).outbound.sending_enabled, false);
  assert.deepEqual(calls, [draft, draft + "/stage", parked, "/api/parks/decide", parked]);
});
