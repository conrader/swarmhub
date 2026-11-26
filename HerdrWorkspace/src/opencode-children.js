import { childControls } from "./child-control.js";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";

const types = ["session.execution.started", "session.execution.succeeded", "session.execution.failed",
  "session.execution.interrupted", "session.step.started", "session.step.ended"];
const shorten = (text, length) => typeof text === "string" ? text.slice(0, length) : "";

async function belongsToRoot(ctx, parent, rootFile) {
  // Standalone Mini has its own server. API launches bind the server to a specific root session.
  if (!rootFile) return true;
  const root = readFileSync(rootFile, "utf8");
  const seen = new Set();
  while (parent && !seen.has(parent)) {
    if (parent === root) return true;
    seen.add(parent);
    parent = (await ctx.session.get({ sessionID: parent }))?.parentID;
  }
  return false;
}

function snapshot(session, messages) {
  const lines = [];
  let task = "", reply = "", model;
  for (const message of messages) {
    if (message.type === "user") {
      task = shorten(message.text, 8000).replace(/^You are a subagent spawned by another session\.\n/, "");
      reply = "";
      if (task) lines.push("Task " + task);
    } else if (message.type === "assistant") {
      if (message.model?.id) model = [message.model.providerID, message.model.id].filter(Boolean).join("/");
      const parts = message.content ?? [];
      for (const part of parts) {
        if (part.type === "tool") {
          const state = part.state ?? {};
          lines.push([state.status, part.name, shorten(state.input?.path, 512)].filter(Boolean).join(" · "));
        }
      }
      const text = parts.filter(p => p.type === "text").map(p => p.text).join("\n\n").trim();
      if (text) lines.push("OpenCode " + shorten(text, 24000));
      if (message.finish === "stop" || message.finish === "length") reply = text;
    }
  }
  const time = session.time;
  const ended = time.idle >= time.busy ? time.idle : null;
  const state = !ended ? "working" : session.outcome === "failed" ? "error"
    : session.outcome === "interrupted" ? "stopped" : reply ? "answered" : "finished";
  return { id: session.id, parent: session.parentID, name: shorten(session.title || session.agent, 120) || "OpenCode agent",
    model: shorten(model, 240) || null, created_ms: time.created, completed_ms: ended,
    state, task: shorten(task, 300), reply: shorten(reply, 300), transcript: lines.join("\n\n").slice(-30000) };
}

function save(executable, data) {
  return new Promise((resolve, reject) => {
    const proc = execFile(executable, ["capture-opencode-child"], { timeout: 5000 }, error => error ? reject(error) : resolve());
    proc.stdin.on("error", () => {});
    proc.stdin.end(JSON.stringify(data));
  });
}

// Read child activity on a separate subscription so saving it cannot hold up a parent reply.
export async function observeChildren(ctx, executable, signal) {
  const controls = childControls(ctx, process.env.SWARMHUB_LAUNCH_KEY);
  signal.addEventListener("abort", () => controls.close(), { once: true });
  try {
    for await (const {type, data} of ctx.event.subscribe({types, signal})) {
      try {
        const session = await ctx.session.get({sessionID: data.sessionID});
        if (!session?.parentID || !await belongsToRoot(ctx, session.parentID, process.env.SWARMHUB_OPENCODE_USAGE_ROOT)) continue;
        const turn = await controls.observe(session, type === "session.execution.started").catch(() => null);
        const messages = await ctx.session.context({sessionID: session.id});
        const value = snapshot(session, messages);
        value.active_turn = turn;
        await save(executable, value).catch(() => save(executable, value));
      } catch {
        if (!signal.aborted) console.warn("SwarmHub could not record an OpenCode child activity update.");
      }
    }
  } finally { controls.close(); }
}
