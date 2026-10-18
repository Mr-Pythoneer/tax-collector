// The relay server: docs/parent-link-v1.md §6. It passes sealed boxes between one computer and
// its parents' phones and serves the parent app. It can't open any box: it sees who is talking
// to whom, when, and how much, and nothing else.
import http from "node:http";
import { Store } from "./store.mjs";
import { RateLimiter, clientAddress, proxyTrust } from "./ratelimit.mjs";
import { loadStatic, CSP } from "./static.mjs";
import * as u from "./util.mjs";

const MINUTE = 60_000;
const DAY = 86_400_000;

export const LIMITS = Object.freeze({
  channels: 8,
  devicesPerChannel: 8,
  waitingPerChannel: 2,
  pairLookupsPerMinute: 10,
  unauthenticatedPerMinute: 60,
  staticPerMinute: 600,
  bodyBytes: 300 * 1024,
  requestTimeoutMs: 40_000,
  maxWaitSeconds: 25,
  stateCopyBytes: 256 * 1024,
  commandBoxBytes: 16 * 1024,
  commandsPerChannel: 500,
  commandMaxAgeMs: 14 * DAY,
  pairSlotMs: 10 * MINUTE,
  pairMessagesPerDirection: 4,
  pairBoxBytes: 4 * 1024,
  pairSlotsPerChannel: 4,
  unlinkedMarkerMs: 30 * DAY,
});

const JSON_TYPE = "application/json; charset=utf-8";
const CLOSED_SLOT_MS = 2 * MINUTE;
const API_CSP = "default-src 'none'; frame-ancestors 'none'";

/** Wakes long-polling requests when something they wait for arrives. */
class Waiters {
  #sets = new Map();

  count(key) {
    return this.#sets.get(key)?.size ?? 0;
  }

  /** Resolves on notify, after `ms`, or when the client goes away. */
  wait(key, ms, res) {
    return new Promise((resolve) => {
      let set = this.#sets.get(key);
      if (!set) this.#sets.set(key, (set = new Set()));
      const done = () => {
        clearTimeout(timer);
        res.off("close", done);
        set.delete(done);
        if (set.size === 0 && this.#sets.get(key) === set) this.#sets.delete(key);
        resolve();
      };
      const timer = setTimeout(done, ms);
      res.once("close", done);
      set.add(done);
    });
  }

  notify(key) {
    for (const done of [...(this.#sets.get(key) ?? [])]) done();
  }

  notifyAll() {
    for (const set of [...this.#sets.values()]) for (const done of [...set]) done();
  }
}

export class Relay {
  /** Opens the data folder (making the setup code on first start) and returns a ready relay. */
  static async open(options) {
    const relay = new Relay(options);
    await relay.#load();
    return relay;
  }

  constructor({ dataDir, staticRoot, setupCode, now = Date.now, log = console, trustProxy = "loopback", logRequests = false, limits = {} }) {
    this.now = now;
    this.fixedSetupCode = setupCode ? u.normaliseCode(setupCode) : null;
    if (this.fixedSetupCode !== null && this.fixedSetupCode.length !== 12) throw new Error("A setup code has 12 letters and numbers (Crockford base32).");
    this.log = log;
    this.trustProxy = proxyTrust(trustProxy);
    this.logRequests = logRequests;
    this.limits = { ...LIMITS, ...limits };
    this.store = new Store(dataDir, { log });
    this.dataDir = this.store.dir;
    this.static = staticRoot ? loadStatic(staticRoot, log) : new Map();
    this.channels = new Map(); // channel ID → channel
    this.computerIndex = new Map(); // computer token hash → channel ID
    this.deviceIndex = new Map(); // device token hash → { ch, dev }
    this.unlinked = new Map(); // channel ID → when it was removed
    this.slots = new Map(); // pairing slot → { ch, hello, createdAt, expiresAt, toComputer, toPhone }
    this.closedSlots = new Map(); // pairing slot → { toPhone, until }: deleted, still readable for a moment
    this.waiters = new Waiters();
    this.limiters = {
      lookup: new RateLimiter(this.limits.pairLookupsPerMinute, { now }),
      unauthenticated: new RateLimiter(this.limits.unauthenticatedPerMinute, { now }),
      static: new RateLimiter(this.limits.staticPerMinute, { now }),
    };
    this.closing = false;
    this.firstStart = false;
  }

  // ---------------------------------------------------------------- storage

  #files(ch) {
    const key = u.fileKey(ch);
    return { meta: `channels/${key}.json`, state: `channels/${key}.state.json`, commands: `channels/${key}.commands.json` };
  }

  async #load() {
    const info = this.store.readJson("server.json");
    if (info && typeof info.instance === "string" && typeof info.setupCode === "string" && info.setupCode.length === 12) {
      this.instance = info.instance;
      this.setupCode = info.setupCode;
      this.createdAt = info.createdAt;
    } else {
      // A new data folder: a new instance ID, so computers can tell the server lost its data.
      this.instance = u.randomId(16);
      this.setupCode = u.randomCode(12);
      this.createdAt = this.now();
      this.firstStart = true;
    }
    // TC_SETUP_CODE pins the code, so computers can link again on their own after a data loss.
    const pinned = this.fixedSetupCode && this.fixedSetupCode !== this.setupCode;
    if (pinned) this.setupCode = this.fixedSetupCode;
    if (this.firstStart || pinned) {
      const doc = { v: 1, instance: this.instance, setupCode: this.setupCode, createdAt: this.createdAt };
      await this.store.save("server.json", () => JSON.stringify(doc, null, 2) + "\n");
    }

    for (const name of this.store.list("channels")) {
      if (!/^[0-9a-f]{32}\.json$/.test(name)) continue;
      const meta = this.store.readJson("channels/" + name);
      if (!meta || !u.isId16(meta.id) || !u.isHash(meta.tokenHash) || !Array.isArray(meta.devices)) continue;
      if (this.#files(meta.id).meta !== "channels/" + name) continue;
      const c = this.#newChannel(meta.id, meta.tokenHash, meta.createdAt);
      c.devices = meta.devices.filter((d) => u.isDeviceId(d?.id) && u.isHash(d?.tokenHash)).slice(0, this.limits.devicesPerChannel);
      c.seen = u.isCount(meta.seen) ? meta.seen : 0;
      c.awake = meta.awake === true;
      const st = this.store.readJson(this.#files(c.id).state);
      if (st && u.isCount(st.seq) && st.copies && typeof st.copies === "object") {
        const copies = {};
        for (const d of c.devices) if (typeof st.copies[d.id] === "string") copies[d.id] = st.copies[d.id];
        c.state = { seq: st.seq, updatedAt: u.isCount(st.updatedAt) ? st.updatedAt : 0, copies, digests: digestsOf(copies) };
      }
      const cm = this.store.readJson(this.#files(c.id).commands);
      if (cm && Array.isArray(cm.commands)) {
        c.lastSeq = u.isCount(cm.lastSeq) ? cm.lastSeq : 0;
        c.ackedUpTo = u.isCount(cm.ackedUpTo) ? Math.min(cm.ackedUpTo, c.lastSeq) : 0;
        c.commands = cm.commands.filter(
          (x) => u.isCount(x?.seq) && x.seq > c.ackedUpTo && x.seq <= c.lastSeq && u.isDeviceId(x.dev) && typeof x.box === "string" && u.isCount(x.receivedAt),
        );
      }
      this.#index(c);
    }

    const unlinked = this.store.readJson("unlinked.json");
    if (unlinked && typeof unlinked === "object") {
      for (const [ch, at] of Object.entries(unlinked)) if (u.isId16(ch) && u.isCount(at)) this.unlinked.set(ch, at);
    }
    const pairing = this.store.readJson("pairing.json");
    if (pairing && typeof pairing.slots === "object") {
      for (const [slot, s] of Object.entries(pairing.slots)) {
        if (!u.isId16(slot) || !this.channels.has(s?.ch) || !(s.expiresAt > this.now())) continue;
        const msgs = (list) => (Array.isArray(list) ? list.filter((m) => u.isCount(m?.n) && typeof m.box === "string") : []);
        this.slots.set(slot, { ch: s.ch, hello: s.hello, createdAt: s.createdAt, expiresAt: s.expiresAt, toComputer: msgs(s.toComputer), toPhone: msgs(s.toPhone) });
      }
    }
    this.sweep();
  }

  #newChannel(id, tokenHash, createdAt) {
    return { id, tokenHash, createdAt: u.isCount(createdAt) ? createdAt : this.now(), devices: [], seen: 0, awake: false, asleepAt: 0, state: null, commands: [], lastSeq: 0, ackedUpTo: 0, metaDirty: false };
  }

  #index(c) {
    this.channels.set(c.id, c);
    this.computerIndex.set(c.tokenHash, c.id);
    for (const d of c.devices) this.deviceIndex.set(d.tokenHash, { ch: c.id, dev: d.id });
  }

  #unindex(c) {
    if (this.computerIndex.get(c.tokenHash) === c.id) this.computerIndex.delete(c.tokenHash);
    for (const d of c.devices) if (this.deviceIndex.get(d.tokenHash)?.ch === c.id) this.deviceIndex.delete(d.tokenHash);
  }

  // Each save writes whatever channel holds that ID when the write happens, and deletes the
  // file if none does. So a save queued for a channel that was since removed (or removed and
  // made again) can't bring the old one back or delete the new one's file.
  #saveMeta(c) {
    c.metaDirty = false;
    const id = c.id;
    return this.store.save(this.#files(id).meta, () => {
      const cur = this.channels.get(id);
      if (!cur) return undefined;
      const { tokenHash, createdAt, devices, seen, awake } = cur;
      return JSON.stringify({ v: 1, id, tokenHash, createdAt, devices, seen, awake });
    });
  }

  #saveState(c) {
    const id = c.id;
    return this.store.save(this.#files(id).state, () => {
      const cur = this.channels.get(id);
      if (!cur?.state) return undefined;
      const { seq, updatedAt, copies } = cur.state;
      return JSON.stringify({ v: 1, seq, updatedAt, copies });
    });
  }

  #saveCommands(c) {
    const id = c.id;
    return this.store.save(this.#files(id).commands, () => {
      const cur = this.channels.get(id);
      if (!cur) return undefined;
      return JSON.stringify({ v: 1, lastSeq: cur.lastSeq, ackedUpTo: cur.ackedUpTo, commands: cur.commands });
    });
  }

  #saveUnlinked() {
    return this.store.save("unlinked.json", () => JSON.stringify(Object.fromEntries(this.unlinked)));
  }

  #savePairing() {
    return this.store.save("pairing.json", () => JSON.stringify({ v: 1, slots: Object.fromEntries(this.slots) }));
  }

  /** Drops what has expired and saves liveness. Runs every 30 seconds, and on demand in tests. */
  sweep() {
    const now = this.now();
    let pairingChanged = false;
    for (const [slot, s] of this.slots) {
      if (s.expiresAt <= now) {
        this.slots.delete(slot);
        pairingChanged = true;
        this.waiters.notify("pair:" + slot + ":toComputer");
        this.waiters.notify("pair:" + slot + ":toPhone");
      }
    }
    if (pairingChanged) this.#savePairing();
    for (const [slot, c] of this.closedSlots) if (c.until <= now) this.closedSlots.delete(slot);
    let unlinkedChanged = false;
    for (const [ch, at] of this.unlinked) {
      if (now - at >= this.limits.unlinkedMarkerMs) {
        this.unlinked.delete(ch);
        unlinkedChanged = true;
      }
    }
    if (unlinkedChanged) this.#saveUnlinked();
    for (const c of this.channels.values()) {
      if (this.#pruneCommands(c)) this.#saveCommands(c);
      if (c.metaDirty) this.#saveMeta(c);
    }
    for (const limiter of Object.values(this.limiters)) limiter.prune();
  }

  #pruneCommands(c) {
    const cutoff = this.now() - this.limits.commandMaxAgeMs;
    const before = c.commands.length;
    c.commands = c.commands.filter((x) => x.seq > c.ackedUpTo && x.receivedAt > cutoff);
    return c.commands.length !== before;
  }

  /** Answers every waiting request and writes everything out. */
  async close() {
    this.closing = true;
    this.waiters.notifyAll();
    for (const c of this.channels.values()) if (c.metaDirty) this.#saveMeta(c);
    await this.store.flush();
  }

  // ---------------------------------------------------------------- HTTP

  /** An http.Server for this relay, with the limits of §6.3. */
  createServer() {
    const server = http.createServer((req, res) => this.handle(req, res));
    server.requestTimeout = this.limits.requestTimeoutMs;
    server.headersTimeout = Math.min(20_000, this.limits.requestTimeoutMs);
    server.keepAliveTimeout = 5_000;
    server.setTimeout(this.limits.requestTimeoutMs + 5_000);
    return server;
  }

  async handle(req, res) {
    const started = Date.now();
    res.on("error", () => {});
    res.setHeader("X-TC-Instance", this.instance);
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
    const watchdog = setTimeout(() => {
      if (!res.writableEnded) this.#error(res, new u.HttpError(503, "The request took too long"));
    }, this.limits.requestTimeoutMs);
    let route = "?";
    try {
      let url;
      try {
        url = new URL(req.url ?? "/", "http://relay.invalid");
      } catch {
        throw new u.HttpError(400, "That isn't a path this server knows how to read");
      }
      if (url.pathname.startsWith("/v1/")) route = await this.#api(req, res, url);
      else route = this.#serveStatic(req, res, url);
    } catch (e) {
      if (!(e instanceof u.HttpError)) {
        this.#logUnexpected(e);
        e = new u.HttpError(500, "Something went wrong on the server");
      }
      this.#error(res, e);
    } finally {
      clearTimeout(watchdog);
      if (this.logRequests) {
        this.log.log(`${new Date().toISOString()} ${req.method} ${route} ${res.statusCode} ${Date.now() - started}ms`);
      }
    }
  }

  #send(res, status, body, headers = {}) {
    if (res.headersSent || res.destroyed) return;
    const text = body === undefined ? "" : JSON.stringify(body);
    const head = { "Cache-Control": "no-store", "Content-Security-Policy": API_CSP, ...headers };
    if (text) {
      head["Content-Type"] = JSON_TYPE;
      head["Content-Length"] = Buffer.byteLength(text);
    }
    res.writeHead(status, head);
    res.end(text);
  }

  #error(res, e) {
    const status = e.status ?? 500;
    const headers = e.headers ?? {};
    this.#send(res, status, { error: u.ERROR_CODES[status] ?? "error", message: e.message, ...e.extra }, headers);
  }

  #serveStatic(req, res, url) {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" });
      res.end("Method not allowed\n");
      return "static";
    }
    const wait = this.limiters.static.take(clientAddress(req, this.trustProxy));
    if (wait) {
      res.writeHead(429, { "Retry-After": String(wait), "Content-Type": "text/plain; charset=utf-8" });
      res.end("Too many requests\n");
      return "static";
    }
    const file = this.static.get(url.pathname);
    if (!file) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
      res.end("Not found\n");
      return "static";
    }
    const headers = {
      "Content-Type": file.type,
      "Cache-Control": "no-cache",
      ETag: file.etag,
      "Content-Security-Policy": CSP,
      "Cross-Origin-Opener-Policy": "same-origin",
      "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
    };
    if (matchesEtag(req.headers["if-none-match"], file.etag)) {
      res.writeHead(304, headers);
      res.end();
      return url.pathname;
    }
    headers["Content-Length"] = file.body.length;
    res.writeHead(200, headers);
    res.end(req.method === "HEAD" ? undefined : file.body);
    return url.pathname;
  }

  // ---------------------------------------------------------------- API plumbing

  /** Routes one API request. Returns a log-safe route name (no IDs, no tokens). */
  async #api(req, res, url) {
    const parts = url.pathname.split("/").slice(2); // after "/v1"
    const m = req.method;
    const ctx = { req, res, url, ip: clientAddress(req, this.trustProxy), hash: bearerHash(req), started: this.now() };
    const known = ctx.hash && (this.computerIndex.has(ctx.hash) || this.deviceIndex.has(ctx.hash));

    let handler = null;
    let name = "/v1/?";
    let lookup = false;
    const [a, b, c] = parts;
    if (a === "health" && parts.length === 1 && m === "GET") [handler, name] = [() => this.#health(ctx), "/v1/health"];
    else if (a === "channels" && parts.length === 2) {
      name = "/v1/channels/" + tag(b);
      if (m === "PUT") handler = () => this.#createChannel(ctx, b);
      if (m === "DELETE") handler = () => this.#deleteChannel(ctx, b);
    } else if (a === "ch" && parts.length >= 3) {
      const path = parts.slice(2).join("/");
      name = "/v1/ch/" + tag(b) + "/" + (["devices", "state", "cmd", "cmd/ack", "presence"].includes(path) ? path : "?");
      if (path === "devices" && m === "PUT") handler = () => this.#putDevices(ctx, b);
      else if (path === "state" && m === "PUT") handler = () => this.#putState(ctx, b);
      else if (path === "state" && m === "GET") handler = () => this.#getState(ctx, b);
      else if (path === "cmd" && m === "POST") handler = () => this.#postCommand(ctx, b);
      else if (path === "cmd" && m === "GET") handler = () => this.#getCommands(ctx, b);
      else if (path === "cmd/ack" && m === "POST") handler = () => this.#ack(ctx, b);
      else if (path === "presence" && m === "POST") handler = () => this.#presence(ctx, b);
    } else if (a === "pair" && (parts.length === 2 || parts.length === 3)) {
      name = "/v1/pair/…" + (c === "toComputer" || c === "toPhone" ? "/" + c : c ? "/?" : "");
      if (parts.length === 2) {
        if (m === "PUT") handler = () => this.#putSlot(ctx, b);
        if (m === "GET") [handler, lookup] = [() => this.#getSlot(ctx, b), true];
        if (m === "DELETE") handler = () => this.#deleteSlot(ctx, b);
      } else if (c === "toComputer" || c === "toPhone") {
        if (m === "POST") handler = () => this.#postPairMessage(ctx, b, c);
        if (m === "GET") handler = () => this.#getPairMessages(ctx, b, c);
      }
    }

    // §6.3: lookups 10 a minute; other calls without a valid token, 60 a minute.
    const wait = lookup ? this.limiters.lookup.take(ctx.ip) : known ? 0 : this.limiters.unauthenticated.take(ctx.ip);
    if (wait) throw new u.HttpError(429, "Too many requests. Try again in a minute.", undefined, { "Retry-After": String(wait) });
    if (!handler) throw new u.HttpError(404, "No such endpoint");
    await handler();
    return name;
  }

  async #body(ctx, max = this.limits.bodyBytes) {
    const { req } = ctx;
    const declared = Number(req.headers["content-length"]);
    const limit = Math.min(max, this.limits.bodyBytes);
    const tooLarge = () => {
      ctx.res.setHeader("Connection", "close");
      ctx.res.once("finish", () => req.destroy());
      return new u.HttpError(413, "Too large");
    };
    if (declared > limit) {
      // Read and drop a body up to a few times the limit, so the client sees the 413 rather
      // than a connection reset partway through its upload.
      if (declared <= 4 * limit) await drain(req, 1000);
      throw tooLarge();
    }
    const chunks = [];
    let size = 0;
    try {
      for await (const chunk of req) {
        size += chunk.length;
        if (size > limit) throw tooLarge();
        chunks.push(chunk);
      }
    } catch (e) {
      if (e instanceof u.HttpError) throw e;
      throw new u.HttpError(400, "The request was cut off");
    }
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      throw new u.HttpError(400, "The body isn't JSON");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new u.HttpError(400, "The body must be a JSON object");
    return body;
  }

  #query(ctx, name, max) {
    const raw = ctx.url.searchParams.get(name);
    if (raw === null || raw === "") return 0;
    if (!/^\d{1,15}$/.test(raw)) throw new u.HttpError(400, `"${name}" must be a whole number`);
    return Math.min(Number(raw), max);
  }

  #checkChannelId(ch) {
    if (!u.isId16(ch)) throw new u.HttpError(400, "Not a channel ID");
  }

  #gone(ch) {
    const at = this.unlinked.get(ch);
    if (at !== undefined) throw new u.HttpError(410, "This computer was unlinked", { unlinkedAt: at });
  }

  /** The channel, if the bearer is its computer token. Every computer request counts as a sign of life. */
  #asComputer(ctx, ch) {
    this.#checkChannelId(ch);
    this.#gone(ch);
    const c = this.channels.get(ch);
    if (!c) throw new u.HttpError(404, "No such channel");
    if (!ctx.hash || !u.sameSecret(ctx.hash, c.tokenHash)) throw new u.HttpError(401, "Not this computer's token");
    this.#alive(c);
    return c;
  }

  /** The channel and device, if the bearer is a token registered on this channel. */
  #asPhone(ctx, ch) {
    this.#checkChannelId(ch);
    this.#gone(ch);
    const found = ctx.hash && this.deviceIndex.get(ctx.hash);
    if (!found) throw new u.HttpError(401, "This phone isn't paired with this server");
    if (found.ch !== ch) throw new u.HttpError(403, "This phone belongs to another computer");
    return { c: this.channels.get(ch), dev: found.dev };
  }

  /** A computer request is starting: the computer is here, and awake (§6.1). */
  #alive(c) {
    c.seen = this.now();
    c.awake = true;
    c.asleepAt = 0;
    c.metaDirty = true;
  }

  /**
   * A waiting request from the computer has ended. It was here until now, unless it said it was
   * going to sleep while this request was open; either way, "awake" is only changed by requests
   * starting and by presence.
   */
  #touch(c, started) {
    if (!c || (c.asleepAt && c.asleepAt >= started)) return;
    c.seen = this.now();
    c.metaDirty = true;
  }

  /** Unexpected errors are server bugs; logged, but at most 10 a minute so they can't fill a disk. */
  #logUnexpected(e) {
    const now = Date.now();
    const w = (this.errorWindow ??= { start: now, count: 0, dropped: 0 });
    if (now - w.start > 60_000) {
      if (w.dropped) this.log.error(`(${w.dropped} more errors in the last minute weren't logged)`);
      Object.assign(w, { start: now, count: 0, dropped: 0 });
    }
    if (++w.count <= 10) this.log.error("Request failed: " + (e?.stack ?? e));
    else w.dropped++;
  }

  // ---------------------------------------------------------------- endpoints

  #health(ctx) {
    this.#send(ctx.res, 200, { ok: true, v: 1, instance: this.instance, time: this.now() });
  }

  async #createChannel(ctx, ch) {
    this.#checkChannelId(ch);
    const body = await this.#body(ctx, 4096);
    if (!ctx.hash) throw new u.HttpError(401, "Send the computer token as a Bearer token");
    if (!u.isHash(body.tokenHash) || body.tokenHash !== ctx.hash) throw new u.HttpError(400, "tokenHash must be the SHA-256 of the token");
    const existing = this.channels.get(ch);
    // Its own computer is told so even if the setup code has changed since.
    if (existing && u.sameSecret(existing.tokenHash, ctx.hash)) {
      this.#alive(existing);
      this.#send(ctx.res, 200, { ch, created: false });
      return;
    }
    if (typeof body.setupCode !== "string" || !u.sameSecret(u.normaliseCode(body.setupCode), this.setupCode)) {
      throw new u.HttpError(403, "Wrong setup code");
    }
    if (existing) throw new u.HttpError(409, "This channel belongs to another computer");
    if (this.channels.size >= this.limits.channels) throw new u.HttpError(429, "This server already has as many computers as it allows");
    if (this.computerIndex.has(ctx.hash) || this.deviceIndex.has(ctx.hash)) throw new u.HttpError(409, "That token is in use");
    const c = this.#newChannel(ch, ctx.hash, this.now());
    this.#alive(c);
    this.#index(c);
    const wasUnlinked = this.unlinked.delete(ch);
    await Promise.all([this.#saveMeta(c), this.#saveCommands(c), wasUnlinked && this.#saveUnlinked()]);
    this.log.log(`Computer ${u.shortHash(ch)} linked`);
    this.#send(ctx.res, 201, { ch, created: true });
  }

  async #deleteChannel(ctx, ch) {
    const c = this.#asComputer(ctx, ch);
    this.#unindex(c);
    this.channels.delete(ch);
    this.unlinked.set(ch, this.now());
    let slotsChanged = false;
    for (const [slot, s] of this.slots) {
      if (s.ch === ch) {
        this.slots.delete(slot);
        slotsChanged = true;
        this.waiters.notify("pair:" + slot + ":toComputer");
        this.waiters.notify("pair:" + slot + ":toPhone");
      }
    }
    this.waiters.notify("cmd:" + ch);
    const files = this.#files(ch);
    await Promise.all([
      this.store.remove(files.meta),
      this.store.remove(files.state),
      this.store.remove(files.commands),
      this.#saveUnlinked(),
      slotsChanged && this.#savePairing(),
    ]);
    this.log.log(`Computer ${u.shortHash(ch)} unlinked`);
    this.#send(ctx.res, 204);
  }

  async #putDevices(ctx, ch) {
    this.#asComputer(ctx, ch);
    const body = await this.#body(ctx, 8192);
    const c = this.#asComputer(ctx, ch); // again: the channel may have gone while the body arrived
    const list = body.devices;
    if (!Array.isArray(list)) throw new u.HttpError(400, '"devices" must be a list');
    if (list.length > this.limits.devicesPerChannel) throw new u.HttpError(400, `At most ${this.limits.devicesPerChannel} phones per computer`);
    const ids = new Set();
    const hashes = new Set();
    for (const d of list) {
      if (!u.isDeviceId(d?.id) || !u.isHash(d?.tokenHash)) throw new u.HttpError(400, "Each device needs an id (lowercase UUID) and a tokenHash");
      if (ids.has(d.id) || hashes.has(d.tokenHash)) throw new u.HttpError(400, "A device is listed twice");
      const owner = this.deviceIndex.get(d.tokenHash);
      if ((owner && owner.ch !== ch) || this.computerIndex.has(d.tokenHash)) throw new u.HttpError(409, "That token is in use");
      ids.add(d.id);
      hashes.add(d.tokenHash);
    }
    this.#unindex(c);
    c.devices = list.map((d) => ({ id: d.id, tokenHash: d.tokenHash }));
    this.#index(c);
    const saves = [this.#saveMeta(c)];
    if (c.state && Object.keys(c.state.copies).some((dev) => !ids.has(dev))) {
      for (const dev of Object.keys(c.state.copies)) if (!ids.has(dev)) delete c.state.copies[dev];
      c.state.digests = digestsOf(c.state.copies);
      saves.push(this.#saveState(c));
    }
    await Promise.all(saves);
    this.#send(ctx.res, 204);
  }

  async #putState(ctx, ch) {
    this.#asComputer(ctx, ch);
    const body = await this.#body(ctx);
    const c = this.#asComputer(ctx, ch);
    if (!u.isCount(body.seq)) throw new u.HttpError(400, '"seq" must be a whole number');
    if (!body.copies || typeof body.copies !== "object" || Array.isArray(body.copies)) throw new u.HttpError(400, '"copies" must be an object');
    const entries = Object.entries(body.copies);
    if (entries.length > this.limits.devicesPerChannel) throw new u.HttpError(400, "Too many copies");
    const registered = new Set(c.devices.map((d) => d.id));
    const copies = {};
    for (const [dev, box] of entries) {
      if (!u.isDeviceId(dev)) throw new u.HttpError(400, "Copies are keyed by device ID");
      u.checkBox(box, this.limits.stateCopyBytes, "Each copy");
      if (registered.has(dev)) copies[dev] = box;
    }
    c.state = { seq: body.seq, updatedAt: this.now(), copies, digests: digestsOf(copies) };
    await this.#saveState(c);
    this.#send(ctx.res, 204);
  }

  #getState(ctx, ch) {
    const { c, dev } = this.#asPhone(ctx, ch);
    const now = this.now();
    // A waiting request for commands is the heartbeat: while one is open, the computer is here now.
    const computerSeen = this.waiters.count("cmd:" + ch) > 0 && c.awake ? now : c.seen;
    const live = {
      "X-TC-Server-Time": String(now),
      "X-TC-Computer-Seen": String(computerSeen),
      "X-TC-Computer-Awake": String(c.awake),
    };
    const box = c.state?.copies[dev];
    if (!box) {
      this.#send(ctx.res, 204, undefined, live);
      return;
    }
    const { seq, updatedAt } = c.state;
    // The ETag leaves out serverTime and computerSeen, which change all the time; the headers
    // above carry them on a 304 as well.
    const etag = '"' + u.sha256([seq, updatedAt, c.state.digests[dev], c.awake, c.ackedUpTo, c.lastSeq].join("|")).toString("base64url").slice(0, 22) + '"';
    if (matchesEtag(ctx.req.headers["if-none-match"], etag)) {
      this.#send(ctx.res, 304, undefined, { ...live, ETag: etag });
      return;
    }
    this.#send(ctx.res, 200, { seq, box, updatedAt, serverTime: now, computerSeen, computerAwake: c.awake, ackedUpTo: c.ackedUpTo, lastCmdSeq: c.lastSeq }, { ...live, ETag: etag });
  }

  async #postCommand(ctx, ch) {
    this.#asPhone(ctx, ch);
    const body = await this.#body(ctx, Math.ceil((this.limits.commandBoxBytes * 4) / 3) + 256);
    const { c, dev } = this.#asPhone(ctx, ch); // again: the phone may have been removed meanwhile
    u.checkBox(body.box, this.limits.commandBoxBytes, "A command");
    this.#pruneCommands(c);
    if (c.commands.length >= this.limits.commandsPerChannel) throw new u.HttpError(429, "Too many commands are waiting for this computer");
    const receivedAt = this.now();
    const seq = ++c.lastSeq;
    c.commands.push({ seq, dev, box: body.box, receivedAt });
    this.waiters.notify("cmd:" + ch);
    await this.#saveCommands(c);
    this.#send(ctx.res, 201, { seq, receivedAt });
  }

  async #getCommands(ctx, ch) {
    const c = this.#asComputer(ctx, ch);
    const wait = this.#query(ctx, "wait", this.limits.maxWaitSeconds);
    const key = "cmd:" + ch;
    if (this.#pruneCommands(c)) this.#saveCommands(c);
    if (c.commands.length === 0 && wait > 0 && !this.closing) {
      if (this.waiters.count(key) >= this.limits.waitingPerChannel) throw new u.HttpError(429, "Too many waiting requests for this computer");
      await this.waiters.wait(key, wait * 1000, ctx.res);
      if (this.channels.get(ch) !== c) {
        this.#gone(ch);
        throw new u.HttpError(404, "No such channel");
      }
      this.#touch(c, ctx.started);
    }
    this.#send(ctx.res, 200, { serverTime: this.now(), commands: c.commands.map(({ seq, dev, box, receivedAt }) => ({ seq, dev, box, receivedAt })) });
  }

  async #ack(ctx, ch) {
    this.#asComputer(ctx, ch);
    const body = await this.#body(ctx, 1024);
    const c = this.#asComputer(ctx, ch);
    if (!u.isCount(body.upTo)) throw new u.HttpError(400, '"upTo" must be a whole number');
    const upTo = Math.min(body.upTo, c.lastSeq);
    if (upTo > c.ackedUpTo) {
      c.ackedUpTo = upTo;
      c.commands = c.commands.filter((x) => x.seq > upTo);
      await this.#saveCommands(c);
    }
    this.#send(ctx.res, 204);
  }

  async #presence(ctx, ch) {
    this.#asComputer(ctx, ch);
    const body = await this.#body(ctx, 1024);
    const c = this.#asComputer(ctx, ch);
    if (typeof body.awake !== "boolean") throw new u.HttpError(400, '"awake" must be true or false');
    c.awake = body.awake;
    c.asleepAt = body.awake ? 0 : this.now();
    await this.#saveMeta(c);
    this.#send(ctx.res, 204);
  }

  // ---------------------------------------------------------------- pairing

  #checkSlotId(slot) {
    if (!u.isId16(slot)) throw new u.HttpError(400, "Not a pairing slot");
  }

  /** The slot, or 404. A miss from someone without a token counts as a guess (§4.3). */
  #slot(ctx, slot, guessCounts) {
    this.#checkSlotId(slot);
    const s = this.slots.get(slot);
    if (s && s.expiresAt > this.now()) return s;
    if (s) this.sweep();
    if (guessCounts) {
      const wait = this.limiters.lookup.take(ctx.ip);
      if (wait) throw new u.HttpError(429, "Too many requests. Try again in a minute.", undefined, { "Retry-After": String(wait) });
    }
    throw new u.HttpError(404, "No such pairing code, or it expired");
  }

  /** The slot, if the bearer is the computer token of the channel that made it. */
  #slotAsComputer(ctx, slot) {
    this.#checkSlotId(slot);
    // Without a computer token, say nothing about whether the slot exists.
    if (!ctx.hash || !this.computerIndex.has(ctx.hash)) throw new u.HttpError(401, "Not a computer's token");
    const s = this.#slot(ctx, slot, false);
    this.#asComputer(ctx, s.ch);
    return s;
  }

  async #putSlot(ctx, slot) {
    this.#checkSlotId(slot);
    const body = await this.#body(ctx, 8192);
    if (!u.isId16(body.ch)) throw new u.HttpError(400, '"ch" must be a channel ID');
    this.#asComputer(ctx, body.ch);
    u.checkBox(body.hello, this.limits.pairBoxBytes, '"hello"');
    const existing = this.slots.get(slot);
    if (existing && existing.expiresAt > this.now() && existing.ch !== body.ch) throw new u.HttpError(409, "That pairing slot is taken");
    const others = [...this.slots.entries()].filter(([k, s]) => s.ch === body.ch && k !== slot && s.expiresAt > this.now()).length;
    if (others >= this.limits.pairSlotsPerChannel) throw new u.HttpError(429, "Too many pairing codes at once");
    const now = this.now();
    this.slots.set(slot, { ch: body.ch, hello: body.hello, createdAt: now, expiresAt: now + this.limits.pairSlotMs, toComputer: [], toPhone: [] });
    await this.#savePairing();
    this.#send(ctx.res, 201, { expiresAt: now + this.limits.pairSlotMs });
  }

  #getSlot(ctx, slot) {
    const s = this.#slot(ctx, slot, false);
    this.#send(ctx.res, 200, { hello: s.hello });
  }

  async #deleteSlot(ctx, slot) {
    this.#checkSlotId(slot);
    if (!ctx.hash || !this.computerIndex.has(ctx.hash)) throw new u.HttpError(401, "Not a computer's token");
    const s = this.slots.get(slot);
    if (s) {
      this.#asComputer(ctx, s.ch);
      this.slots.delete(slot);
      // The computer deletes the slot right after its last message ("done" or "rejected"). A phone
      // between two waits would miss it, so its messages stay readable for a couple of minutes.
      this.closedSlots.set(slot, { toPhone: s.toPhone, until: this.now() + CLOSED_SLOT_MS });
      this.waiters.notify("pair:" + slot + ":toComputer");
      this.waiters.notify("pair:" + slot + ":toPhone");
      await this.#savePairing();
    }
    this.#send(ctx.res, 204);
  }

  /** A slot the computer deleted a moment ago, whose last messages a phone may still read. */
  #closedSlot(slot) {
    const c = this.closedSlots.get(slot);
    if (c && c.until > this.now()) return c;
    if (c) this.closedSlots.delete(slot);
    return null;
  }

  async #postPairMessage(ctx, slot, direction) {
    const s = direction === "toPhone" ? this.#slotAsComputer(ctx, slot) : this.#slot(ctx, slot, true);
    const body = await this.#body(ctx, 8192);
    u.checkBox(body.box, this.limits.pairBoxBytes, '"box"');
    if (this.slots.get(slot) !== s) throw new u.HttpError(404, "No such pairing code, or it expired");
    const list = s[direction];
    if (list.length >= this.limits.pairMessagesPerDirection) throw new u.HttpError(409, "This pairing code has had all the messages it can take");
    const n = list.length + 1;
    list.push({ n, box: body.box });
    this.waiters.notify("pair:" + slot + ":" + direction);
    await this.#savePairing();
    this.#send(ctx.res, 201, { n });
  }

  async #getPairMessages(ctx, slot, direction) {
    const after = this.#query(ctx, "after", Number.MAX_SAFE_INTEGER);
    const wait = this.#query(ctx, "wait", this.limits.maxWaitSeconds);
    this.#checkSlotId(slot);
    const closed = direction === "toPhone" && !this.slots.has(slot) ? this.#closedSlot(slot) : null;
    if (closed) {
      const left = closed.toPhone.filter((x) => x.n > after);
      if (!left.length) throw new u.HttpError(404, "No such pairing code, or it expired");
      this.#send(ctx.res, 200, { messages: left });
      return;
    }
    const s = direction === "toComputer" ? this.#slotAsComputer(ctx, slot) : this.#slot(ctx, slot, true);
    const key = "pair:" + slot + ":" + direction;
    const fresh = () => s[direction].filter((x) => x.n > after);
    if (fresh().length === 0 && wait > 0 && !this.closing) {
      if (this.waiters.count(key) >= this.limits.waitingPerChannel) throw new u.HttpError(429, "Too many waiting requests for this pairing code");
      await this.waiters.wait(key, wait * 1000, ctx.res);
      if (this.slots.get(slot) !== s && !(direction === "toPhone" && this.#closedSlot(slot) && fresh().length)) {
        throw new u.HttpError(404, "No such pairing code, or it expired");
      }
    }
    if (direction === "toComputer") this.#touch(this.channels.get(s.ch), ctx.started);
    this.#send(ctx.res, 200, { messages: fresh() });
  }
}

// ---------------------------------------------------------------- helpers

function bearerHash(req) {
  const m = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization ?? "");
  const token = m && u.unb64(m[1]);
  return token && token.length === 32 ? u.b64(u.sha256(token)) : null;
}

/** Reads and drops what's left of a request body, for at most `ms`. */
function drain(req, ms) {
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      req.off("end", done).off("error", done).off("close", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    req.on("end", done).on("error", done).on("close", done);
    req.resume();
  });
}

function digestsOf(copies) {
  return Object.fromEntries(Object.entries(copies).map(([dev, box]) => [dev, u.sha256(box).toString("base64url").slice(0, 22)]));
}

function matchesEtag(header, etag) {
  if (typeof header !== "string") return false;
  return header.split(",").some((t) => {
    const v = t.trim();
    return v === "*" || v === etag || v === "W/" + etag;
  });
}

/** Channel IDs only appear in logs as short hashes. */
const tag = (id) => (u.isId16(id) ? "#" + u.shortHash(id) : "?");
