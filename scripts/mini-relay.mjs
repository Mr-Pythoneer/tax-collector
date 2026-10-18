// A small in-memory relay that follows docs/parent-link-v1.md §6, for testing the computer's side of the
// parent link before the real server (server/) exists. Not for real use: no rate limits, nothing saved.
//   node scripts/mini-relay.mjs [port] [setupCode]
import { createServer } from "node:http";
import { createHash, randomBytes } from "node:crypto";

const port = Number(process.argv[2] || 8787);
const setupCode = process.argv[3] || "TESTSETUPCODE";
const instance = randomBytes(8).toString("base64url");
const hash = (token) => createHash("sha256").update(Buffer.from(token, "base64url")).digest("base64url");

const channels = new Map(); // ch → {tokenHash, devices: Map(id → tokenHash), state: {seq, copies, updatedAt}, cmds: [], acked, seq, seen, awake, waiters: []}
const slots = new Map();    // slot → {ch, hello, toComputer: [], toPhone: [], waiters: []}

function send(res, status, body) {
  const json = body === undefined ? "" : JSON.stringify({ ...body, serverTime: Date.now() });
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", "x-tc-instance": instance });
  res.end(json);
}

const bearer = (req) => (req.headers.authorization || "").replace(/^Bearer /, "");
function computer(req, ch) {
  const c = channels.get(ch);
  return c && c.tokenHash === hash(bearer(req)) ? c : null;
}
function phone(req, ch) {
  const c = channels.get(ch);
  if (!c) return null;
  const h = hash(bearer(req));
  for (const [id, th] of c.devices) if (th === h) return { c, dev: id };
  return null;
}
function wake(list) { while (list.length) list.shift()(); }
const waitFor = (list, seconds) => new Promise((resolve) => {
  const t = setTimeout(resolve, seconds * 1000);
  list.push(() => { clearTimeout(t); resolve(); });
});

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const parts = url.pathname.split("/").filter(Boolean);
  let body = {};
  if (req.method !== "GET" && req.method !== "DELETE") {
    let raw = "";
    for await (const chunk of req) raw += chunk;
    try { body = raw ? JSON.parse(raw) : {}; } catch { return send(res, 400, { error: "bad_request" }); }
  }
  const [v1, kind, id, sub, sub2] = parts;
  if (v1 !== "v1") return send(res, 404, { error: "not_found" });

  if (kind === "health") return send(res, 200, { ok: true, v: 1, instance, time: Date.now() });

  if (kind === "channels" && req.method === "PUT") {
    if (body.setupCode !== setupCode) return send(res, 403, { error: "forbidden" });
    if (hash(bearer(req)) !== body.tokenHash) return send(res, 401, { error: "unauthorized" });
    const existing = channels.get(id);
    if (existing && existing.tokenHash !== body.tokenHash) return send(res, 409, { error: "conflict" });
    if (existing) return send(res, 200, {});
    channels.set(id, { tokenHash: body.tokenHash, devices: new Map(), state: null, cmds: [], acked: 0, seq: 0, seen: Date.now(), awake: true, waiters: [] });
    return send(res, 201, {});
  }
  if (kind === "channels" && req.method === "DELETE") {
    if (!computer(req, id)) return send(res, 401, { error: "unauthorized" });
    channels.delete(id);
    return send(res, 204);
  }

  if (kind === "ch") {
    const ch = id;
    if (sub === "devices" && req.method === "PUT") {
      const c = computer(req, ch);
      if (!c) return send(res, channels.has(ch) ? 401 : 404, { error: "unauthorized" });
      c.devices = new Map((body.devices || []).map((d) => [d.id, d.tokenHash]));
      return send(res, 204);
    }
    if (sub === "state" && req.method === "PUT") {
      const c = computer(req, ch);
      if (!c) return send(res, channels.has(ch) ? 401 : 404, { error: "unauthorized" });
      c.seen = Date.now(); c.awake = true;
      c.state = { seq: body.seq, copies: body.copies || {}, updatedAt: Date.now() };
      return send(res, 204);
    }
    if (sub === "state" && req.method === "GET") {
      const p = phone(req, ch);
      if (!p) return send(res, 401, { error: "unauthorized" });
      const s = p.c.state;
      if (!s || !s.copies[p.dev]) return send(res, 204);
      return send(res, 200, { seq: s.seq, box: s.copies[p.dev], updatedAt: s.updatedAt, computerSeen: p.c.seen,
        computerAwake: p.c.awake, ackedUpTo: p.c.acked, lastCmdSeq: p.c.seq });
    }
    if (sub === "cmd" && !sub2 && req.method === "POST") {
      const p = phone(req, ch);
      if (!p) return send(res, 401, { error: "unauthorized" });
      const cmd = { seq: ++p.c.seq, dev: p.dev, box: body.box, receivedAt: Date.now() };
      p.c.cmds.push(cmd);
      wake(p.c.waiters);
      return send(res, 201, { seq: cmd.seq, receivedAt: cmd.receivedAt });
    }
    if (sub === "cmd" && !sub2 && req.method === "GET") {
      const c = computer(req, ch);
      if (!c) return send(res, channels.has(ch) ? 401 : 404, { error: "unauthorized" });
      c.seen = Date.now(); c.awake = true;
      const pending = () => c.cmds.filter((x) => x.seq > c.acked);
      if (!pending().length) await waitFor(c.waiters, Math.min(25, Number(url.searchParams.get("wait") || 0)));
      c.seen = Date.now();
      return send(res, 200, { commands: pending() });
    }
    if (sub === "cmd" && sub2 === "ack") {
      const c = computer(req, ch);
      if (!c) return send(res, 401, { error: "unauthorized" });
      c.acked = Math.max(c.acked, body.upTo || 0);
      c.cmds = c.cmds.filter((x) => x.seq > c.acked);
      return send(res, 204);
    }
    if (sub === "presence") {
      const c = computer(req, ch);
      if (!c) return send(res, 401, { error: "unauthorized" });
      c.awake = !!body.awake;
      return send(res, 204);
    }
  }

  if (kind === "pair") {
    const slot = id;
    if (!sub && req.method === "PUT") {
      if (!computer(req, body.ch)) return send(res, 401, { error: "unauthorized" });
      slots.set(slot, { ch: body.ch, hello: body.hello, toComputer: [], toPhone: [], waiters: [] });
      setTimeout(() => slots.delete(slot), 600_000);
      return send(res, 201, {});
    }
    const s = slots.get(slot);
    if (!s) return send(res, 404, { error: "not_found" });
    if (!sub && req.method === "GET") return send(res, 200, { hello: s.hello });
    if (!sub && req.method === "DELETE") { slots.delete(slot); return send(res, 204); }
    const list = sub === "toComputer" ? s.toComputer : sub === "toPhone" ? s.toPhone : null;
    if (!list) return send(res, 404, { error: "not_found" });
    if (req.method === "POST") {
      if (list.length >= 4) return send(res, 429, { error: "rate_limited" });
      list.push({ n: list.length + 1, box: body.box });
      wake(s.waiters);
      return send(res, 201, { n: list.length });
    }
    const after = Number(url.searchParams.get("after") || 0);
    if (!list.some((m) => m.n > after)) await waitFor(s.waiters, Math.min(25, Number(url.searchParams.get("wait") || 0)));
    return send(res, 200, { messages: list.filter((m) => m.n > after) });
  }
  send(res, 404, { error: "not_found" });
}).listen(port, "127.0.0.1", () => console.log(`mini relay on http://127.0.0.1:${port} (setup code ${setupCode})`));
