import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, rmdirSync } from "node:fs";
import { createServer } from "node:net";

function working(session, busy) {
  return Number.isSafeInteger(busy) && session?.time?.busy === busy &&
    !(session.time.idle >= busy);
}

// A socket belongs to one observed execution. Never reuse it for another turn, even in the same child.
async function openTurn(ctx, key, session) {
  const busy = session.time.busy;
  const turn = randomBytes(16).toString("hex");
  const digest = createHash("sha256").update([key, session.parentID, session.id, turn].join("\n")).digest("hex").slice(0, 32);
  const directory = "/tmp/swarmhub-oc-stop-" + digest;
  mkdirSync(directory, { mode: 0o700 });
  let closed = false, stopping = false;
  const server = createServer(socket => {
    socket.setTimeout(8000, () => socket.destroy());
    socket.on("error", () => socket.destroy());
    socket.once("data", async request => {
      if (closed || stopping || request.length !== 1 || request[0] !== 83) { socket.end("N"); return; }
      stopping = true;
      try {
        const live = await ctx.session.get({sessionID: session.id});
        if (closed || socket.destroyed || live?.id !== session.id || live.parentID !== session.parentID || !working(live, busy)) {
          socket.end("N");
          return;
        }
        const result = await ctx.session.interrupt({sessionID: session.id, resume: false});
        socket.end(result?.interrupted ? "Y" : "N");
      } catch { socket.end("?"); }
      finally { stopping = false; }
    });
  });
  const clean = () => { try { rmdirSync(directory); } catch {} };
  server.once("close", clean);
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(directory + "/stop", resolve);
    });
  } catch (e) { clean(); throw e; }
  return { busy, turn, close() { closed = true; server.close(); } };
}

export function childControls(ctx, key) {
  const active = new Map();
  let closed = false;
  return {
    async observe(session, started) {
      const entry = active.get(session.id);
      if (entry && !started && working(session, entry.busy)) return entry.turn;
      if (entry) { entry.close(); active.delete(session.id); }
      if (closed || !working(session, session.time.busy)) return null;
      const control = await openTurn(ctx, key, session);
      if (closed) { control.close(); return null; }
      active.set(session.id, control);
      return control.turn;
    },
    close() {
      closed = true;
      for (const entry of active.values()) entry.close();
      active.clear();
    },
  };
}
