import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import assert from "node:assert/strict";
import { test } from "node:test";

const script = readFileSync(new URL("../web/chat-model.js", import.meta.url), "utf8");

function fixture(frames, program = "Claude Code") {
  const keys = [];
  let frame = 0;
  const window = { chatModelTerminal: {
    ready: () => true, closed: () => frame >= frames.length,
    lines: () => frames[frame].screen, promptLine: () => frames[frame].prompt ?? "",
    key: value => keys.push(value),
  }};
  runInNewContext(script, { window, setTimeout: callback => queueMicrotask(() => { frame++; callback(); }) });
  frame = -1;
  return { keys, result: window.chooseChatModel(program, "fable", "Fable 5.2") };
}

const menu = (first, second) => ({screen:["Select model", first, second, "Enter to set as default · s to use this session only · Esc to cancel"]});
const end = {screen:["⎿ Set model to Fable 5.2", "❯"], prompt:"❯"};
test("selects the exact Claude model with the session-only shortcut and observes fresh confirmation", async () => {
  const run = fixture([{screen:["❯"],prompt:"❯"}, {screen:["❯ /model"],prompt:"❯ /model"},
    menu("❯ Sonnet 5.5","Fable 5.2  A description"),menu("Sonnet 5.5","❯ Fable 5.2  A description"), end]);
  assert.equal(await run.result,true);
  assert.deepEqual(run.keys,["/model","\r","\x1b[B","s"]);
});

test("never submits a draft, a different model variant, or a stale confirmation", async () => {
  const stale = { screen:["⎿ Set model to Fable 5.2","❯","❯ unfinished"], prompt:"❯ unfinished" };
  const run = fixture([stale, menu("❯ Fable 5.2 extended","Sonnet 5.5"),end]);
  await assert.rejects(run.result);
  assert.deepEqual(run.keys,[]);
});
test("Codex leaves model and effort confirmation to the user", async () => {
  const run = fixture([menu("❯ Fable 5.2","Other"),end],"Codex");
  assert.equal(await run.result,true);
  assert.deepEqual(run.keys,[]);
});
