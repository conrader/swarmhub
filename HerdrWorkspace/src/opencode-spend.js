import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const chatPackages = new Set([
  "@opencode/ai/providers/openai-compatible", "@opencode/ai/providers/deepseek",
  "@opencode/ai/providers/openrouter",
]);
const unsupported = "This capped session needs an HTTP chat model with known token prices and limits.";
const count = value => Number.isSafeInteger(value) && value >= 0;
const rate = value => Number.isFinite(value) && value >= 0;

// OpenCode's catalog prices are USD per million tokens. Use the most expensive
// tier even when a smaller prompt will likely qualify for a cheaper one.
export function quote(model) {
  if (!chatPackages.has(model?.package) || !model.cost?.length) throw new Error(unsupported);
  let input = 0, output = 0;
  for (const tier of model.cost) {
    const prices = [tier.input, tier.output, tier.cache?.read, tier.cache?.write];
    if (!prices.every(rate)) throw new Error(unsupported);
    input = Math.max(input, tier.input + Math.max(tier.cache.read, tier.cache.write));
    output = Math.max(output, tier.output);
  }
  const context = model.limit?.context, answer = model.limit?.output;
  if (!count(context) || !context || !count(answer) || !answer || !(input || output)) throw new Error(unsupported);
  function nanos(promptTokens, completionTokens) {
    if (!count(promptTokens) || !count(completionTokens)) throw new Error(unsupported);
    const value = Math.ceil((promptTokens * input + completionTokens * output) * 1000);
    if (!count(value)) throw new Error(unsupported);
    return value;
  }
  return { maximum: nanos(context, answer), nanos };
}

// Forward exactly the original bytes. Only a complete OpenAI-compatible SSE
// response with a consistent final usage receipt can release a reservation.
function meteredBody(response, settle) {
  const decoder = new TextDecoder();
  let buffer = "", receipt, done = false, invalid = false;
  function line(text) {
    if (!text.startsWith("data:")) return;
    const data = text.slice(5).trim();
    if (done) { invalid = true; return; }
    if (data === "[DONE]") { done = true; return; }
    const usage = JSON.parse(data).usage;
    if (usage == null) return;
    const {prompt_tokens: input, completion_tokens: output, total_tokens: total} = usage;
    if (!count(input) || !count(output) || !count(total) || input + output !== total || total === 0 ||
        (receipt && (input !== receipt.input || output !== receipt.output))) invalid = true;
    else receipt = {input, output};
  }
  const stream = response.body.pipeThrough(new TransformStream({
    transform(chunk, controller) {
      controller.enqueue(chunk);
      if (invalid) return;
      try {
        // Limit only the metering parser. Large content still reaches the bot.
        for (let offset = 0; offset < chunk.length && !invalid; offset += 8192) {
          const lines = (buffer + decoder.decode(chunk.subarray(offset, offset + 8192), {stream:true})).split("\n");
          buffer = lines.pop();
          for (const value of lines) line(value);
          if (buffer.length > 128 * 1024) invalid = true;
        }
      } catch { invalid = true; }
    },
    flush() {
      if (invalid) return;
      try {
        line(buffer + decoder.decode());
        if (!invalid && done && receipt) settle(receipt);
      } catch { /* Keep the full reservation when the receipt cannot be saved. */ }
    },
  }));
  return new Response(stream, {status:response.status, statusText:response.statusText, headers:response.headers});
}

export async function installSpendLimit(ctx, executable, launch) {
  const pending = new WeakMap();
  function record(entry) {
    execFileSync(executable, ["opencode-spend"], { input: JSON.stringify(entry), timeout: 3000,
      stdio: ["pipe", "ignore", "pipe"] });
  }
  async function pricing(ref) {
    const {data} = await ctx.model.list();
    return quote(data.find(m => m.providerID === ref.providerID && m.id === ref.id));
  }
  // Keep the first paid request available for the user's work. OpenCode would
  // otherwise race a second paid request to name this private chat.
  await ctx.session.hook("title", input => { input.result = "SwarmHub"; });
  await ctx.session.hook("model.request", input => pricing(input.model).then(() => {}));
  await ctx.session.hook("experimental.ws.handshake", () => { throw new Error(unsupported); });
  await ctx.session.hook("http.request", async input => {
    const price = await pricing(input.model);
    if (input.request.method !== "POST" || !new URL(input.request.url).pathname.endsWith("/chat/completions")) throw new Error(unsupported);
    const body = await input.request.clone().json();
    if (body.n !== undefined && body.n !== 1) throw new Error(unsupported);
    const request = randomUUID();
    try { record({action:"reserve", request, nanos:price.maximum}); }
    catch { throw new Error("OpenCode could not reserve this request within the session spending limit."); }
    pending.set(input.request, {request, price});
  });
  await ctx.session.hook("http.response", input => {
    const entry = pending.get(input.request);
    if (!entry) return;
    pending.delete(input.request);
    const r = input.response;
    if (!r.ok || !r.body || !r.headers.get("content-type")?.startsWith("text/event-stream")) return;
    input.response = meteredBody(r, ({input, output}) =>
      record({action:"settle", request:entry.request, nanos:entry.price.nanos(input, output)}));
  });
  writeFileSync(process.env.SWARMHUB_OPENCODE_CAP_READY, launch, {mode:0o600});
}
