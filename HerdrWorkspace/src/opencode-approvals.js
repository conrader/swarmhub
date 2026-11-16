import { createConnection } from "node:net";

const actions = new Set(["read", "glob", "grep"]);

export function approvalDesk(ctx, key) {
  const path = process.env.SWARMHUB_APPROVAL_SOCKET;
  const pending = new Map();
  const enabled = Boolean(path && process.env.SWARMHUB_OPENCODE_APPROVALS === "1");

  function open(request, rootID) {
    const { id, sessionID, action, resources } = request;
    if (!enabled || pending.size >= 16 || pending.has(id) || !id || !sessionID
      || !actions.has(action) || !resources?.length || resources.length > 32
      || !resources.every((item) => typeof item === "string" && item && Buffer.byteLength(item) <= 8192)) return;
    const body = Buffer.from(JSON.stringify({ key, tool: action, provider: "open_code", native_session: sessionID,
      cwd: ctx.location?.directory || "", input: { resources } }));
    if (body.length > 48 * 1024) return;
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length);
    const socket = createConnection(path);
    const review = { socket, rootID, applying: false };
    pending.set(id, review);
    socket.unref();
    socket.setTimeout(49_000, () => socket.destroy());
    socket.on("error", () => socket.destroy());
    socket.once("close", () => {
      if (pending.get(id) === review) pending.delete(id);
    });
    socket.once("connect", () => socket.write(Buffer.concat([header, body])));
    socket.once("data", async (data) => {
      const decision = ({65: "once", 68: "reject"})[data[0]];
      if (!decision || socket.destroyed) { socket.end(); return; }
      review.applying = true;
      try {
        const query = {sessionID, requestID: id};
        const current = await ctx.permission.get(query);
        if (socket.destroyed || current?.action !== action
          || JSON.stringify(current.resources) !== JSON.stringify(resources)) {
          socket.end();
          return;
        }
        await ctx.permission.reply({...query, decision});
        socket.end("K");
      } catch {
        socket.end();
      }
    });
  }

  function close(id) {
    const review = pending.get(id);
    if (review && !review.applying) review.socket.destroy();
  }
  return {
    open,
    close,
    closeFor(rootID) {
      for (const [id, review] of pending) if (review.rootID === rootID) close(id);
    },
    dispose() {
      for (const review of pending.values()) review.socket.destroy();
    },
  };
}
