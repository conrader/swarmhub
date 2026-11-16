import { spawnSync } from "node:child_process";
import { closeSync, constants, openSync, writeSync } from "node:fs";
import { createConnection } from "node:net";
import { approvalDesk } from "./approvals.js";

const types = ["session.execution.started", "session.execution.succeeded", "session.execution.failed",
  "session.execution.interrupted", "session.step.started", "session.step.ended", "session.text.delta", "session.text.ended",
  "permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled"];
const inboxTypes = ["session.inbox.enqueued", "session.inbox.delivered", "session.inbox.cancelled"];
const maxBytes = 128 * 1024;
const previewBytes = 32 * 1024;
const groupPreviewBytes = 2 * 1024;
const finalFinish = (finish) => finish === "stop" || finish === "length";

function terminalStatus() {
  const path = process.env.SWARMHUB_STATUS_TTY;
  let tty = null, last;
  if (path) {
    try {
      // Pin the CLI's PTY once; OpenCode's server can run without a controlling TTY.
      tty = openSync(path, constants.O_WRONLY | constants.O_NOCTTY | constants.O_NONBLOCK);
    } catch { /* Replies still work for sessions without a PTY. */ }
  }
  return {
    report(state, kind) {
      const value = "state=" + state + (kind ? ":kind=" + kind : "");
      if (tty === null || last === value) return;
      try {
        writeSync(tty, "\x1b]7501;" + value + "\x1b\\");
        last = value;
      } catch (error) {
        if (error.code === "EAGAIN" || error.code === "EINTR") return;
        this.close();
      }
    },
    close() {
      if (typeof tty === "number") closeSync(tty);
      tty = null;
    },
  };
}

async function finalText(ctx, sessionID, step) {
  if (step.completed && step.parts?.size) {
    return [...step.parts].sort(([a], [b]) => a - b).map(([, part]) => part).join("\n\n");
  }
  // Completion can arrive before all step events have reached this subscriber.
  // Only recover the exact assistant message from this turn.
  if (step.parts === null) return "";
  const messages = await ctx.session.context({ sessionID }).catch(() => []);
  const message = messages.find((entry) => entry.id === step.id);
  if (message?.type !== "assistant" || !finalFinish(message.finish) || message.error) return "";
  return message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n\n");
}

function saveReply(executable, id, text) {
  // Do not put reply text or the launch identity on the command line.
  const input = JSON.stringify({ id, text });
  const save = () => spawnSync(executable, ["capture-opencode-reply"], {
    input, stdio: ["pipe", "ignore", "ignore"], timeout: 8000,
  });
  const first = save();
  // The journal uses the message ID to make retrying after a timeout safe.
  if (first.status !== 0 && save().status !== 0) {
    console.warn("SwarmHub could not save the OpenCode reply. It remains available in OpenCode.");
  }
}

function startPreview(path, key, id, group) {
  let text = "", bytes = 0, ordinal, capped = false, socket, timer;
  const limit = group ? groupPreviewBytes : previewBytes;
  function flush() {
    timer = undefined;
    if (!text.trim()) return;
    if (!socket) {
      const client = createConnection(path);
      socket = client;
      client.on("error", () => client.destroy());
      client.once("close", () => { if (socket === client) socket = undefined; });
      client.unref();
    }
    if (!socket.destroyed && socket.writableLength < limit) {
      socket.write(JSON.stringify(group
        ? { key, group_preview: group, draft_id: id, draft_text: text }
        : { key, id, text }) + "\n");
    }
  }
  return {
    append(part, delta) {
      if (capped || !delta) return;
      const addition = ordinal !== undefined && ordinal !== part ? "\n\n" + delta : delta;
      const size = Buffer.byteLength(addition);
      if (bytes + size > limit) { capped = true; return; }
      text += addition;
      bytes += size;
      ordinal = part;
      timer ??= setTimeout(flush, 175);
    },
    close() {
      capped = true;
      clearTimeout(timer);
      socket?.destroy();
    },
  };
}

export default {
  id: "swarmhub.replies",
  setup(ctx) {
    const executable = process.env.SWARMHUB_OPENCODE_CAPTURE_BIN;
    const key = process.env.SWARMHUB_LAUNCH_KEY;
    const path = process.env.SWARMHUB_REPLY_SOCKET;
    if (!executable || !key || !process.env.SWARMHUB_JOURNAL) return;
    const controller = new AbortController();
    const running = new Map();
    const inbox = new Map();
    const events = process.env.SWARMHUB_OPENCODE_GROUP_PREVIEW === "1" ? [...types, ...inboxTypes] : types;
    let inboxOverflow = false;
    const status = terminalStatus();
    const approvals = approvalDesk(ctx, key);

    function report(fallback) {
      for (const run of running.values()) {
        const kind = run.waiting.values().next().value;
        if (kind) {
          status.report("blocked", kind);
          return;
        }
      }
      status.report(running.size ? "working" : fallback);
    }

    async function trackPrompt(type, data) {
      const permission = type.startsWith("permission.");
      const kind = permission ? "permission" : "question";
      const opened = type === "permission.asked" || type === "form.created";
      const id = permission && !opened ? data.requestID : (data.form || data).id;
      if (!id) return;
      const key = kind + ":" + id;
      if (!opened) {
        if (permission) approvals.close(id);
        for (const run of running.values()) {
          if (run.waiting.delete(key)) report("idle");
        }
        return;
      }
      let parent = (data.form || data).sessionID;
      for (let depth = 0; parent && depth < 8; ++depth) {
        const run = running.get(parent);
        if (run) {
          if (run.waiting.size < 64) run.waiting.set(key, kind);
          if (permission) approvals.open(data, parent);
          report("idle");
          return;
        }
        parent = (await ctx.session.get({ sessionID: parent }).catch(() => null))?.parentID;
      }
    }

    async function listen() {
      for await (const { type, data } of ctx.event.subscribe({ types: events, signal: controller.signal })) {
        if (type.startsWith("permission.") || type.startsWith("form.")) {
          if (running.size) await trackPrompt(type, data);
          continue;
        }
        const { sessionID, assistantMessageID } = data;
        const run = running.get(sessionID);
        if (type.startsWith("session.inbox.")) {
          if (typeof sessionID !== "string" || typeof data.inboxID !== "string") continue;
          const inputId = sessionID + ":" + data.inboxID;
          if (type === "session.inbox.enqueued") {
            const scope = data.item?.payload?.metadata?.swarmhubGroupPreview;
            const marked = scope && Number.isSafeInteger(scope.delivery) && scope.delivery > 0
              && typeof scope.proof === "string" && /^[a-zA-Z0-9_-]{43}$/.test(scope.proof);
            if (!inbox.has(inputId) && inbox.size >= 256) inboxOverflow = true;
            else {
              // Retain only correlation evidence, never the payload or prompt text.
              inbox.set(inputId, {
                knownUser: data.item?.type === "user" && (scope === undefined || !!marked),
                scope: marked ? { delivery: scope.delivery, proof: scope.proof } : undefined,
              });
            }
            continue;
          }
          const input = inbox.get(inputId);
          inbox.delete(inputId);
          if (type !== "session.inbox.delivered" || !run) continue;
          // A single execution can drain several queued tasks. Bind at the
          // next assistant step and withhold previews if inputs were mixed.
          run.inputs = Math.min(2, run.inputs + 1);
          run.nextGroup ||= input?.scope;
          run.unknownInput ||= !input?.knownUser;
          if (run.step && !run.step.ended && (run.group || run.nextGroup || run.unknownInput || inboxOverflow)) {
            run.step.preview?.close();
            run.step.suppressPreview = true;
            run.interleaved = true;
          }
          continue;
        }
        if (type === "session.execution.started") {
          if (running.size >= 16) continue;
          const session = await ctx.session.get({ sessionID }).catch(() => null);
          if (session && !session.parentID) {
            running.get(sessionID)?.step?.preview?.close();
            running.set(sessionID, { step: null, waiting: new Map(), inputs: 0 });
            report("idle");
          }
          continue;
        }
        if (!run) continue;
        if (type === "session.step.started") {
          run.step?.preview?.close();
          if (run.inputs) {
            run.ambiguous = run.unknownInput || run.interleaved || (run.inputs > 1 && !!run.nextGroup);
            run.group = run.inputs === 1 ? run.nextGroup : undefined;
          }
          run.interleaved = false;
          run.inputs = 0;
          run.nextGroup = undefined;
          run.unknownInput = false;
          run.step = { id: assistantMessageID, parts: new Map(), bytes: 0, completed: false, ended: false,
            suppressPreview: inboxOverflow || run.ambiguous };
        } else if (type === "session.text.delta" && path && run.step?.id === assistantMessageID && !run.step.suppressPreview) {
          run.step.preview ??= startPreview(path, key, assistantMessageID, run.group);
          run.step.preview.append(data.ordinal, data.delta);
        } else if (type === "session.text.ended" && run.step?.id === assistantMessageID) {
          const step = run.step;
          if (!step.parts || step.parts.has(data.ordinal)) continue;
          step.bytes += Buffer.byteLength(data.text);
          if (step.bytes > maxBytes || step.parts.size >= 256) step.parts = null;
          else step.parts.set(data.ordinal, data.text);
        } else if (type === "session.step.ended" && run.step?.id === assistantMessageID) {
          run.step.ended = true;
          run.step.completed = finalFinish(data.finish);
          if (!run.step.completed || run.group) run.step.preview?.close();
        } else if (type.startsWith("session.execution.")) {
          const step = run.step;
          if (type === "session.execution.succeeded" && step) {
            const text = await finalText(ctx, sessionID, step);
            if (text.trim() && Buffer.byteLength(text) <= maxBytes) {
              saveReply(executable, step.id, text);
            }
          }
          step?.preview?.close();
          running.delete(sessionID);
          approvals.closeFor(sessionID);
          report(({ "session.execution.succeeded": "done", "session.execution.failed": "error" })[type] || "idle");
        }
      }
    }
    function close() {
      for (const run of running.values()) run.step?.preview?.close();
      if (running.size) status.report("clear");
      running.clear();
      approvals.dispose();
      status.close();
    }
    void listen().catch(() => {}).finally(close);
    return () => { controller.abort(); close(); };
  },
};
