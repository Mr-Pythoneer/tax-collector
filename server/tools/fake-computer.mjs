#!/usr/bin/env node
// A stand-in for Tax Collector on a computer, for testing the relay and the parent app without a
// Mac. It does the computer's side of docs/parent-link-v1.md with a small homework model in
// memory: makes its channel, pairs phones (approving them by itself), applies commands, and
// uploads state.
//
//   node server/tools/fake-computer.mjs --server http://localhost:8787 --setup-code ABCD-EFGH-JKMN
//       [--name "Test Mac"] [--file fake-computer.json] [--no-seed] [--flag testMode] [--pair] [--approve-delay 8]
//
// While it runs, type: pair, sleep, wake, overdue, proof, flag <kind>, unflag, reject <reason>,
// remove <phone name>, status, quit.
import { readFile, writeFile, rename } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import * as lc from "../../parent/js/linkcrypto.js";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const FRESHNESS = 10 * MINUTE;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CAPABILITIES = ["lock", "tasks", "repeats", "apps", "block", "penalty", "extensions", "message", "approveProof", "guardianSetup"];
const SETTING = { lock: "access", free: "access", normal: "access", setPenalty: "penalty", setExtensions: "extensions" };
const APP_COMMANDS = new Set(["allowApp", "disallowApp", "blockApp", "unblockApp"]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const clean = (text, max) => [...String(text ?? "").replace(/[\n\r\u2028\u2029\u0085\u000b\u000c]/g, " ")].slice(0, max).join("");
const isMs = (v) => Number.isSafeInteger(v) && v >= 0;
const isText = (v, max, { empty = true } = {}) => typeof v === "string" && [...v].length <= max && (empty || v.trim() !== "");
const onlyKeys = (obj, allowed) => obj && typeof obj === "object" && !Array.isArray(obj) && Object.keys(obj).every((k) => allowed.includes(k));

export class FakeComputer {
  constructor({ server, setupCode, name = "Test Mac", platform = "mac", timeZone, log = () => {}, file = null, seed = true, wait = 25, now = Date.now, capabilities = CAPABILITIES }) {
    this.server = server.replace(/\/+$/, "");
    this.setupCode = setupCode;
    this.name = name;
    this.platform = platform;
    this.timeZone = timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone ?? "UTC";
    this.log = log;
    this.file = file;
    this.seed = seed;
    this.wait = wait;
    this.now = now;
    this.capabilities = capabilities;
    this.awake = true;
    this.running = false;
    this.paused = false;
    this.unlinked = false;
    this.instance = null;
    this.needsSync = true;
    this.pollAbort = null;
    this.timeFormat = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: this.timeZone });
  }

  // ------------------------------------------------------------ identity and saving

  async init() {
    if (this.file) {
      try {
        const saved = JSON.parse(await readFile(this.file, "utf8"));
        await this.#restore(saved);
        return this;
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
      }
    }
    this.channel = lc.b64(lc.randomBytes(16));
    this.tokenBytes = lc.randomBytes(32);
    this.token = lc.b64(this.tokenBytes);
    this.tokenHash = lc.b64(await lc.sha256(this.tokenBytes));
    const kp = await globalThis.crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    this.dhPrivate = kp.privateKey;
    this.dhPublic = new Uint8Array(await globalThis.crypto.subtle.exportKey("raw", kp.publicKey));
    this.devices = [];
    this.settingAt = {};
    this.stateSeq = 0;
    this.results = [];
    this.activity = [];
    this.flags = [];
    this.model = this.seed ? seedModel(this.now(), this.timeZone) : emptyModel();
    if (this.seed) this.activity = seedActivity(this.model, this.now());
    await this.save();
    return this;
  }

  async #restore(s) {
    this.channel = s.channel;
    this.token = s.token;
    this.tokenBytes = lc.unb64(s.token);
    this.tokenHash = lc.b64(await lc.sha256(this.tokenBytes));
    this.dhPrivate = await globalThis.crypto.subtle.importKey("jwk", s.dhPrivate, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    this.dhPublic = lc.unb64(s.dhPublic);
    this.devices = s.devices;
    this.settingAt = s.settingAt ?? {};
    this.stateSeq = s.stateSeq ?? 0;
    this.results = s.results ?? [];
    this.activity = s.activity ?? [];
    this.flags = s.flags ?? [];
    this.model = s.model;
    this.instance = s.instance ?? null;
  }

  async save() {
    if (!this.file) return;
    const doc = {
      channel: this.channel, token: this.token, dhPublic: lc.b64(this.dhPublic),
      dhPrivate: await globalThis.crypto.subtle.exportKey("jwk", this.dhPrivate),
      devices: this.devices, settingAt: this.settingAt, stateSeq: this.stateSeq, results: this.results,
      activity: this.activity, flags: this.flags, model: this.model, instance: this.instance,
    };
    const tmp = this.file + ".tmp";
    await writeFile(tmp, JSON.stringify(doc, null, 1), { mode: 0o600 });
    await rename(tmp, this.file);
  }

  // ------------------------------------------------------------ talking to the relay

  async api(method, path, body, { signal, token = this.token } = {}) {
    const headers = { Authorization: "Bearer " + token };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(this.server + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal });
    const instance = res.headers.get("X-TC-Instance");
    if (instance && this.instance && instance !== this.instance) {
      this.log(`The server's instance changed (${this.instance} → ${instance}): linking again.`);
      this.needsSync = true;
    }
    if (instance && !this.instance) this.instance = instance;
    const text = res.status === 204 || res.status === 304 ? "" : await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    return { status: res.status, json, headers: res.headers, instance };
  }

  /** Makes the channel (or confirms it's ours), registers the phones and uploads state. */
  async connect() {
    const res = await this.api("PUT", `/v1/channels/${this.channel}`, { setupCode: this.setupCode, tokenHash: this.tokenHash });
    if (res.status === 403) throw new Error("The server says the setup code is wrong.");
    if (res.status === 409) throw new Error("Another computer holds this channel on the server.");
    if (res.status !== 201 && res.status !== 200) throw new Error(`Couldn't make the channel: ${res.status} ${res.json?.message ?? ""}`);
    this.instance = res.instance;
    this.unlinked = false;
    await this.registerDevices();
    this.needsSync = false;
    await this.uploadState();
    await this.save();
    return res.status;
  }

  async registerDevices(extra = []) {
    const devices = [...this.devices.map((d) => ({ id: d.id, tokenHash: d.tokenHash })), ...extra];
    const res = await this.api("PUT", `/v1/ch/${this.channel}/devices`, { devices });
    if (res.status !== 204) throw new Error(`Couldn't register phones: ${res.status} ${res.json?.message ?? ""}`);
  }

  async uploadState() {
    this.stateSeq += 1;
    const json = JSON.stringify(this.buildState());
    const copies = {};
    for (const d of this.devices) {
      copies[d.id] = await lc.sealState({ linkKey: lc.unb64(d.linkKey), channel: this.channel, deviceId: d.id, json });
    }
    const res = await this.api("PUT", `/v1/ch/${this.channel}/state`, { seq: this.stateSeq, copies });
    if (res.status !== 204) throw new Error(`Couldn't upload state: ${res.status} ${res.json?.message ?? ""}`);
    this.lastUpload = this.now();
    this.lastUploadedBody = stateFingerprint(json);
    await this.save();
  }

  async presence(awake) {
    await this.api("POST", `/v1/ch/${this.channel}/presence`, { awake });
  }

  async sleep() {
    this.awake = false;
    this.pollAbort?.abort();
    await this.presence(false);
    this.log("Asleep.");
  }

  async wake() {
    this.awake = true;
    await this.presence(true);
    await this.uploadState();
    this.log("Awake.");
  }

  // ------------------------------------------------------------ pairing (§4.2, computer side)

  /**
   * Shows a pairing code and runs the pairing in the background. `approve(name, code)` decides
   * (by default: yes, as TAXCOLLECTOR_TEST_PAIR_AUTOCONFIRM does on a test Mac).
   * Returns { code, result } where result resolves to { ok, device?, why? }.
   */
  async startPairing({ approve = async () => true, code = lc.randomCode(10) } = {}) {
    const { slot, pairKey } = await lc.pairingSecrets(code);
    const hello = { t: "hello", v: 1, ch: this.channel, name: this.name, platform: this.platform, dhKey: lc.b64(this.dhPublic) };
    const made = await this.api("PUT", `/v1/pair/${slot}`, { ch: this.channel, hello: await lc.sealPairing(pairKey, slot, hello) });
    if (made.status !== 201) throw new Error(`The server wouldn't start pairing: ${made.status} ${made.json?.message ?? ""}`);
    const result = this.#runPairing(slot, pairKey, approve);
    return { code, formatted: lc.formatPairingCode(code), slot, result };
  }

  async #runPairing(slot, pairKey, approve) {
    const deadline = this.now() + 10 * MINUTE;
    let after = 0;
    const fail = async (why) => {
      await this.api("POST", `/v1/pair/${slot}/toPhone`, { box: await lc.sealPairing(pairKey, slot, { t: "rejected", why }) }).catch(() => {});
      await this.api("DELETE", `/v1/pair/${slot}`).catch(() => {});
      this.log("Pairing stopped: " + why);
      return { ok: false, why };
    };
    const messages = async (wait) => {
      const res = await this.api("GET", `/v1/pair/${slot}/toComputer?after=${after}&wait=${wait}`);
      if (res.status !== 200) throw new Error(`The server lost the pairing (${res.status}).`);
      const out = [];
      for (const m of res.json.messages) {
        after = Math.max(after, m.n);
        try {
          out.push(await lc.openPairing(pairKey, slot, m.box));
        } catch {
          // not sealed with this code: ignore
        }
      }
      return out;
    };
    try {
      let commit = null;
      while (!commit) {
        if (this.now() > deadline) return fail("The code ran out. Start again.");
        for (const m of await messages(20)) {
          if (m.t !== "commit") continue;
          if (commit) return fail("Two phones tried to pair at once. Start again.");
          commit = m.commit;
        }
      }
      const computerNonce = lc.randomBytes(32);
      await this.api("POST", `/v1/pair/${slot}/toPhone`, { box: await lc.sealPairing(pairKey, slot, { t: "nonce", nonce: lc.b64(computerNonce) }) });
      let reveal = null;
      while (!reveal) {
        if (this.now() > deadline) return fail("The code ran out. Start again.");
        for (const m of await messages(20)) {
          if (m.t === "commit") return fail("Two phones tried to pair at once. Start again.");
          if (m.t === "reveal") reveal = m;
        }
      }
      let signPub, dhPub, phoneNonce, tokenHash;
      try {
        [signPub, dhPub, phoneNonce, tokenHash] = [reveal.signKey, reveal.dhKey, reveal.nonce, reveal.tokenHash].map(lc.unb64);
      } catch {
        return fail("The phone's answer didn't match. Start again.");
      }
      if (signPub.length !== 65 || dhPub.length !== 65 || phoneNonce.length !== 32 || tokenHash.length !== 32 || typeof reveal.name !== "string") {
        return fail("The phone's answer didn't match. Start again.");
      }
      const recomputed = await lc.commitment({ signPub, dhPub, nonce: phoneNonce, tokenHash, name: reveal.name });
      if (recomputed !== commit) return fail("The phone's answer didn't match. Start again.");
      const name = clean(reveal.name, 40).trim() || "A phone";
      const code = await lc.comparisonCode({ computerNonce, phoneNonce, computerDhPub: this.dhPublic, phoneSignPub: signPub, phoneDhPub: dhPub });
      this.log(`Does ${name} show ${lc.formatComparisonCode(code)}?`);
      this.lastComparison = code;
      if (!(await approve(name, code))) return fail("Pairing was turned down on the computer.");
      // A second commit before approval stops it, even now.
      for (const m of await messages(0)) if (m.t === "commit") return fail("Two phones tried to pair at once. Start again.");

      const id = lc.uuid();
      const shared = await lc.ecdh(this.dhPrivate, dhPub);
      const linkKey = await lc.deriveLinkKey(shared, this.channel, id, { raw: true });
      const device = { id, name, signKey: lc.b64(signPub), dhKey: lc.b64(dhPub), tokenHash: lc.b64(tokenHash), linkKey: lc.b64(linkKey), pairedAt: this.now(), lastCounter: 0 };
      this.devices.push(device);
      await this.registerDevices();
      await this.api("POST", `/v1/pair/${slot}/toPhone`, { box: await lc.sealPairing(pairKey, slot, { t: "done", dev: id }) });
      await this.api("DELETE", `/v1/pair/${slot}`);
      this.addActivity("pair", `Paired ${name}`);
      await this.uploadState();
      this.log(`Paired ${name}.`);
      return { ok: true, device };
    } catch (e) {
      return fail(e.message.startsWith("The server") ? e.message : "Couldn't reach the server: " + e.message);
    }
  }

  // ------------------------------------------------------------ commands (§5.1)

  /** Runs until stop(): waits for commands, applies them, and keeps the state fresh. */
  async run() {
    this.running = true;
    let backoff = 250;
    while (this.running && !this.unlinked) {
      if (!this.awake || this.paused) {
        await sleep(100);
        continue;
      }
      try {
        if (this.needsSync) await this.connect();
        await this.pollOnce(this.wait);
        if (this.now() - (this.lastUpload ?? 0) > 10 * MINUTE || stateFingerprint(JSON.stringify(this.buildState())) !== this.lastUploadedBody) {
          await this.uploadState();
        }
        backoff = 250;
      } catch (e) {
        if (e.name === "AbortError") continue;
        this.log("Offline: " + e.message);
        await sleep(backoff);
        backoff = Math.min(backoff * 2, 3000);
      }
    }
  }

  stop() {
    this.running = false;
    this.pollAbort?.abort();
  }

  /** One wait for commands. Returns how many it handled. */
  async pollOnce(wait = 0) {
    this.pollAbort = new AbortController();
    const res = await this.api("GET", `/v1/ch/${this.channel}/cmd?wait=${wait}`, undefined, { signal: this.pollAbort.signal });
    if (res.status === 404) {
      this.needsSync = true;
      return 0;
    }
    if (res.status === 410) {
      this.unlinked = true;
      this.log("The server says this computer was unlinked.");
      return 0;
    }
    if (res.status !== 200) throw new Error(`Waiting for commands failed: ${res.status}`);
    if (Math.abs(res.json.serverTime - this.now()) > 2 * MINUTE) this.raiseFlag("clockSkew", "The computer's clock is more than 2 minutes off the server's time.");
    const commands = res.json.commands;
    if (commands.length === 0) return 0;
    let upTo = 0;
    for (const c of commands) {
      await this.processCommand(c);
      upTo = Math.max(upTo, c.seq);
    }
    await this.api("POST", `/v1/ch/${this.channel}/cmd/ack`, { upTo });
    await this.uploadState();
    return commands.length;
  }

  /** §5.1 steps 1–7 for one command from the server. */
  async processCommand({ dev, box, receivedAt }) {
    const now = this.now();
    const reject = (reason, extra = {}) => this.record({ dev, n: 0, id: "", type: "", outcome: "rejected", reason, at: now, ...extra });
    const device = this.devices.find((d) => d.id === dev);
    if (!device) return reject("unknown_device");
    const opened = await lc.openCommand({ linkKey: lc.unb64(device.linkKey), signPub: lc.unb64(device.signKey), channel: this.channel, deviceId: dev, box });
    if (!opened.ok) {
      if (opened.reason === "bad_box" || opened.reason === "bad_signature") {
        this.raiseFlag("badCommand", `A command from ${device.name} failed its check (${opened.reason}).`);
      }
      return reject(opened.reason);
    }
    const c = opened.command;
    const ids = { n: Number.isSafeInteger(c.n) ? c.n : 0, id: typeof c.id === "string" ? clean(c.id, 64) : "", type: typeof c.type === "string" ? clean(c.type, 40) : "" };
    if (c.v !== 1 || c.ch !== this.channel || c.dev !== dev) return reject("wrong_target", ids);
    if (!Number.isSafeInteger(c.n) || !isMs(c.at) || typeof c.id !== "string" || typeof c.type !== "string") return reject("bad_args", ids);
    if (c.n <= device.lastCounter) return reject("replayed", { ...ids, last: device.lastCounter });
    if (Math.abs(receivedAt - c.at) > FRESHNESS) return reject("stale", ids);
    device.lastCounter = c.n;
    if (this.rejectNext) {
      // Test aid ("reject <reason>" on the command line): turn down the next good command.
      const reason = this.rejectNext;
      this.rejectNext = null;
      return reject(reason, ids);
    }

    let outcome, reason = "";
    const setting = SETTING[c.type] ?? (APP_COMMANDS.has(c.type) && typeof c.args?.app?.id === "string" ? "app:" + c.args.app.id : null);
    if (!(c.type in COMMANDS) || !this.#supports(c.type)) outcome = "unsupported";
    else if (setting && this.settingAt[setting] > c.at) [outcome, reason] = ["noop", "A newer change came first."];
    else {
      [outcome, reason = ""] = await COMMANDS[c.type].call(this, c.args ?? {}, device, c);
      if (setting && outcome !== "rejected") this.settingAt[setting] = c.at;
    }
    return this.record({ dev, n: c.n, id: c.id, type: c.type, outcome, reason, at: now });
  }

  #supports(type) {
    const needs = { lock: "lock", free: "lock", normal: "lock", addTask: "tasks", editTask: "tasks", deleteTask: "tasks", excuseTask: "tasks",
      approveProof: "approveProof", addRepeat: "repeats", stopRepeat: "repeats", allowApp: "apps", disallowApp: "apps", blockApp: "block",
      unblockApp: "block", setPenalty: "penalty", setExtensions: "extensions", message: "message", allowGuardianSetup: "guardianSetup" }[type];
    return !needs || this.capabilities.includes(needs);
  }

  record(result) {
    this.results.push(result);
    if (this.results.length > 50) this.results.splice(0, this.results.length - 50);
    return result;
  }

  addActivity(kind, text) {
    this.activity.push({ at: this.now(), kind, text: clean(text, 200) });
    if (this.activity.length > 100) this.activity.splice(0, this.activity.length - 100);
  }

  raiseFlag(kind, text) {
    this.flags = this.flags.filter((f) => f.kind !== kind);
    this.flags.push({ kind, text: clean(text, 200), at: this.now() });
  }

  clearFlags() {
    this.flags = [];
  }

  /** Test aid: tells the server about a phone this computer has never paired (§5.1 step 1). */
  async registerExtraDevice(id, tokenHash) {
    await this.registerDevices([{ id, tokenHash }]);
  }

  // ------------------------------------------------------------ the model

  time(ms) {
    return this.timeFormat.format(ms);
  }

  task(id) {
    return this.model.tasks.find((t) => t.id === id);
  }

  expireAccess(now = this.now()) {
    const a = this.model.access;
    if ((a.mode === "locked" || a.mode === "free") && a.until !== null && a.until <= now) {
      this.model.access = { mode: "normal", until: null, strength: null, by: a.by, at: a.at };
    }
  }

  lockReasons(now = this.now()) {
    this.expireAccess(now);
    const a = this.model.access;
    const reasons = [];
    if (a.mode === "locked") reasons.push({ kind: "parent", title: clean(a.by, 100), until: a.until });
    if (a.mode !== "free") {
      for (const t of this.model.tasks) if (t.status === "pending" && t.due <= now) reasons.push({ kind: "overdue", taskId: t.id, title: t.title });
      for (const t of this.model.tasks) {
        if (t.status === "provenLate" && t.penaltyEndsAt > now) reasons.push({ kind: "penalty", taskId: t.id, title: t.title, until: t.penaltyEndsAt });
      }
    }
    return reasons;
  }

  buildState() {
    const now = this.now();
    const reasons = this.lockReasons(now);
    const a = this.model.access;
    const cutoff = now - 14 * DAY;
    const tasks = this.model.tasks
      .filter((t) => t.status === "pending" || (t.statusAt ?? t.due) >= cutoff)
      .sort((x, y) => x.due - y.due)
      .slice(0, 150)
      .map((t) => ({
        id: t.id, title: clean(t.title, 200), course: t.course ? clean(t.course, 100) : null, details: clean(t.details, 500), due: t.due,
        created: t.created, status: t.status, statusAt: t.statusAt ?? null, penaltyEndsAt: t.penaltyEndsAt ?? null, source: t.source,
        repeatId: t.repeatId ?? null, checking: !!t.checking,
        proofs: (t.proofs ?? []).slice(-10).map((p) => ({ ...p, note: clean(p.note, 300), reason: clean(p.reason, 300) })),
        extensions: (t.extensions ?? []).slice(-5),
      }));
    const message = this.model.message && now - this.model.message.at < DAY ? this.model.message : null;
    return {
      v: 1,
      seq: this.stateSeq,
      sentAt: now,
      computer: { name: this.name, platform: this.platform, app: "0.7.0", os: this.platform === "mac" ? "macOS 26.1" : "Windows 11", timeZone: this.timeZone, capabilities: this.capabilities },
      access: { mode: a.mode, until: a.until ?? null, strength: a.strength ?? null, by: a.by ?? "", at: a.at ?? 0 },
      lock: { locked: reasons.length > 0, reasons },
      tasks,
      repeats: this.model.repeats.map((r) => ({ ...r, currentDue: nextDue(r, now, this.timeZone), schedule: scheduleText(r, this.timeZone) })),
      apps: this.model.apps,
      settings: this.model.settings,
      trackRecord: this.model.trackRecord,
      activity: this.activity.slice(-100),
      results: this.results.slice(-50),
      devices: this.devices.map((d) => ({ id: d.id, name: d.name, pairedAt: d.pairedAt })),
      flags: this.flags,
      message,
    };
  }

  /** Test and demo aids. */
  addOverdueTask(title = "Science questions p. 112") {
    const now = this.now();
    const t = newTask({ title, course: "Science", due: now - 20 * MINUTE, created: now - DAY });
    this.model.tasks.push(t);
    this.addActivity("lock", `${title} is overdue: the computer locked`);
    return t;
  }

  addProof(taskId, { note = "Finished it, photo attached.", verdict = "rejected", reason = "The photo is too blurry to read." } = {}) {
    const t = this.task(taskId);
    const p = { id: lc.uuid(), at: this.now(), files: 1, note, verdict, reason };
    t.proofs.push(p);
    return p;
  }
}

// ---------------------------------------------------------------- what each command does (§7)

const appRef = (a) => (onlyKeys(a, ["id", "name"]) && isText(a.id, 300, { empty: false }) && (a.name === undefined || isText(a.name, 100)) ? { id: a.id, name: a.name || a.id } : null);
const BAD = ["rejected", "bad_args"];

const COMMANDS = {
  lock(args, d) {
    if (!onlyKeys(args, ["until", "strength", "note"]) || !(args.until === null || isMs(args.until)) || !["homework", "all"].includes(args.strength)) return BAD;
    if (args.note !== undefined && !isText(args.note, 300)) return BAD;
    if (args.until !== null && args.until <= this.now()) return ["noop", "That time has passed."];
    this.model.access = { mode: "locked", until: args.until, strength: args.strength, by: d.name, at: this.now(), note: args.note ?? null };
    this.addActivity("parent", `${d.name} locked this computer ${args.until === null ? "until further notice" : "until " + this.time(args.until)}`);
    return ["applied"];
  },
  free(args, d) {
    if (!onlyKeys(args, ["until"]) || !isMs(args.until)) return BAD;
    if (args.until <= this.now()) return ["noop", "That time has passed."];
    this.model.access = { mode: "free", until: args.until, strength: null, by: d.name, at: this.now() };
    this.addActivity("parent", `${d.name} unlocked this computer until ${this.time(args.until)}`);
    return ["applied"];
  },
  normal(args, d) {
    if (!onlyKeys(args, [])) return BAD;
    this.expireAccess();
    if (this.model.access.mode === "normal") return ["noop", "Already on the normal rules."];
    this.model.access = { mode: "normal", until: null, strength: null, by: d.name, at: this.now() };
    this.addActivity("parent", `${d.name} put this computer back on the normal rules`);
    return ["applied"];
  },
  addTask(args, d) {
    const t = args.task;
    if (!onlyKeys(args, ["task"]) || !onlyKeys(t, ["id", "title", "details", "due"]) || !UUID.test(t.id) || !isText(t.title, 200, { empty: false }) || !isMs(t.due)) return BAD;
    if (t.details !== undefined && !isText(t.details, 2000)) return BAD;
    if (this.task(t.id)) return ["noop", "It's there already."];
    this.model.tasks.push(newTask({ id: t.id, title: t.title, details: t.details ?? "", due: t.due, created: this.now() }));
    this.addActivity("parent", `${d.name} added ${t.title}, due ${this.time(t.due)}`);
    return ["applied"];
  },
  editTask(args, d) {
    if (!onlyKeys(args, ["id", "title", "details", "due"]) || !UUID.test(args.id)) return BAD;
    if (args.title !== undefined && !isText(args.title, 200, { empty: false })) return BAD;
    if (args.details !== undefined && !isText(args.details, 2000)) return BAD;
    if (args.due !== undefined && !isMs(args.due)) return BAD;
    const t = this.task(args.id);
    if (!t) return ["rejected", "not_found"];
    for (const k of ["title", "details", "due"]) if (args[k] !== undefined) t[k] = args[k];
    this.addActivity("parent", `${d.name} changed ${t.title}`);
    return ["applied"];
  },
  deleteTask(args, d) {
    if (!onlyKeys(args, ["id"]) || !UUID.test(args.id)) return BAD;
    const t = this.task(args.id);
    if (!t) return ["noop", "It's gone already."];
    this.model.tasks = this.model.tasks.filter((x) => x !== t);
    this.addActivity("parent", `${d.name} deleted ${t.title}`);
    return ["applied"];
  },
  excuseTask(args, d) {
    if (!onlyKeys(args, ["id"]) || !UUID.test(args.id)) return BAD;
    const t = this.task(args.id);
    if (!t) return ["rejected", "not_found"];
    if (t.status !== "pending") return ["noop", "It's settled already."];
    Object.assign(t, { status: "excused", statusAt: this.now() });
    this.addActivity("parent", `${d.name} excused ${t.title}`);
    return ["applied"];
  },
  approveProof(args, d) {
    if (!onlyKeys(args, ["taskId", "proofId"]) || !UUID.test(args.taskId) || !UUID.test(args.proofId)) return BAD;
    const t = this.task(args.taskId);
    if (!t) return ["rejected", "not_found"];
    const p = t.proofs.find((x) => x.id === args.proofId);
    if (!p) return ["rejected", "not_found"];
    if (t.status !== "pending") return ["noop", "It's settled already."];
    p.verdict = "guardianApproved";
    p.reason = `Approved by ${d.name}.`; // the computer's own note, as the Mac writes it
    const onTime = p.at <= t.due;
    Object.assign(t, { status: onTime ? "proven" : "provenLate", statusAt: this.now(), checking: false,
      penaltyEndsAt: onTime ? null : this.now() + this.model.settings.penaltyMinutes * MINUTE });
    this.addActivity("parent", `${d.name} approved the proof for ${t.title}${onTime ? "" : " (late)"}`);
    return ["applied"];
  },
  addRepeat(args, d) {
    const r = args.repeat;
    const keys = ["id", "title", "details", "unit", "interval", "weekdays", "minuteOfDay", "startDate"];
    if (!onlyKeys(args, ["repeat"]) || !onlyKeys(r, keys) || !UUID.test(r.id) || !isText(r.title, 200, { empty: false })) return BAD;
    if (r.details !== undefined && !isText(r.details, 2000)) return BAD;
    if (!["days", "weeks"].includes(r.unit) || !Number.isSafeInteger(r.interval) || r.interval < 1 || r.interval > (r.unit === "days" ? 365 : 52)) return BAD;
    if (!Number.isSafeInteger(r.minuteOfDay) || r.minuteOfDay < 0 || r.minuteOfDay >= 1440 || !/^\d{4}-\d{2}-\d{2}$/.test(r.startDate ?? "")) return BAD;
    const weekdays = r.weekdays ?? [];
    if (!Array.isArray(weekdays) || !weekdays.every((w) => Number.isInteger(w) && w >= 1 && w <= 7) || (r.unit === "weeks" && weekdays.length === 0)) return BAD;
    if (this.model.repeats.some((x) => x.id === r.id)) return ["noop", "It's there already."];
    const repeat = { id: r.id, title: r.title, details: r.details ?? "", unit: r.unit, interval: r.interval, weekdays: r.unit === "weeks" ? [...new Set(weekdays)].sort() : [], minuteOfDay: r.minuteOfDay, startDate: r.startDate };
    this.model.repeats.push(repeat);
    const due = nextDue(repeat, this.now(), this.timeZone);
    if (due) this.model.tasks.push(newTask({ title: repeat.title, details: repeat.details, due, created: this.now(), source: "repeat", repeatId: repeat.id }));
    this.addActivity("parent", `${d.name} added the repeating task ${r.title}`);
    return ["applied"];
  },
  stopRepeat(args, d) {
    if (!onlyKeys(args, ["id"]) || !UUID.test(args.id)) return BAD;
    const r = this.model.repeats.find((x) => x.id === args.id);
    if (!r) return ["noop", "It's stopped already."];
    this.model.repeats = this.model.repeats.filter((x) => x !== r);
    this.addActivity("parent", `${d.name} stopped ${r.title} repeating`);
    return ["applied"];
  },
  allowApp(args, d) {
    const app = onlyKeys(args, ["app"]) && appRef(args.app);
    if (!app) return BAD;
    const apps = this.model.apps;
    if (apps.allowed.some((a) => a.id === app.id)) return ["noop", "It's allowed already."];
    apps.allowed.push(app);
    this.addActivity("parent", `${d.name} allowed ${app.name} during locks`);
    return ["applied"];
  },
  disallowApp(args, d) {
    const app = onlyKeys(args, ["app"]) && appRef(args.app);
    if (!app) return BAD;
    const apps = this.model.apps;
    if (!apps.allowed.some((a) => a.id === app.id)) return ["noop", "It wasn't on the list."];
    apps.allowed = apps.allowed.filter((a) => a.id !== app.id);
    this.addActivity("parent", `${d.name} stopped allowing ${app.name} during locks`);
    return ["applied"];
  },
  blockApp(args, d) {
    const app = onlyKeys(args, ["app"]) && appRef(args.app);
    if (!app) return BAD;
    const apps = this.model.apps;
    if (apps.blocked.some((a) => a.id === app.id)) return ["noop", "It's blocked already."];
    apps.blocked.push(app);
    this.addActivity("parent", `${d.name} blocked ${app.name}`);
    return ["applied"];
  },
  unblockApp(args, d) {
    const app = onlyKeys(args, ["app"]) && appRef(args.app);
    if (!app) return BAD;
    const apps = this.model.apps;
    if (!apps.blocked.some((a) => a.id === app.id)) return ["noop", "It wasn't blocked."];
    apps.blocked = apps.blocked.filter((a) => a.id !== app.id);
    this.addActivity("parent", `${d.name} unblocked ${app.name}`);
    return ["applied"];
  },
  setPenalty(args, d) {
    if (!onlyKeys(args, ["minutes"]) || !Number.isSafeInteger(args.minutes) || args.minutes < 0 || args.minutes > 720) return BAD;
    if (this.model.settings.penaltyMinutes === args.minutes) return ["noop", "It's that already."];
    this.model.settings.penaltyMinutes = args.minutes;
    this.addActivity("parent", `${d.name} set the late penalty to ${args.minutes} minutes`);
    return ["applied"];
  },
  setExtensions(args, d) {
    if (!onlyKeys(args, ["enabled"]) || typeof args.enabled !== "boolean") return BAD;
    if (this.model.settings.extensionsEnabled === args.enabled) return ["noop", "It's that already."];
    this.model.settings.extensionsEnabled = args.enabled;
    this.addActivity("parent", `${d.name} turned asking for more time ${args.enabled ? "on" : "off"}`);
    return ["applied"];
  },
  message(args, d) {
    if (!onlyKeys(args, ["text"]) || !isText(args.text, 300, { empty: false })) return BAD;
    this.model.message = { text: clean(args.text, 300), by: d.name, at: this.now() };
    this.addActivity("message", `${d.name}: ${args.text}`);
    return ["applied"];
  },
  allowGuardianSetup(args, d) {
    if (!onlyKeys(args, ["until"]) || !isMs(args.until)) return BAD;
    if (args.until <= this.now()) return ["noop", "That time has passed."];
    this.guardianSetupUntil = Math.min(args.until, this.now() + 15 * MINUTE);
    this.addActivity("parent", `${d.name} allowed setting a new guardian code until ${this.time(this.guardianSetupUntil)}`);
    return ["applied"];
  },
  async removeDevice(args, d) {
    if (!onlyKeys(args, ["id"]) || typeof args.id !== "string" || !args.id) return BAD;
    const gone = this.devices.find((x) => x.id === args.id);
    if (!gone) return ["noop", "No such phone."];
    this.devices = this.devices.filter((x) => x !== gone);
    await this.registerDevices();
    this.addActivity("parent", gone.id === d.id ? `${d.name} unpaired itself` : `${d.name} removed ${gone.name}`);
    return ["applied"];
  },
};

// ---------------------------------------------------------------- repeats

const WEEKDAY = { Sun: 1, Mon: 2, Tue: 3, Wed: 4, Thu: 5, Fri: 6, Sat: 7 };
const DAY_NAMES = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The date parts of `ms` in `timeZone`. */
function zoned(ms, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(ms).map((p) => [p.type, p.value]));
  return { y: +parts.year, m: +parts.month, d: +parts.day, weekday: WEEKDAY[parts.weekday], minute: +parts.hour * 60 + +parts.minute };
}

/** Milliseconds for a wall-clock time in `timeZone` (good to the minute, across DST). */
export function wallTime(y, m, d, minuteOfDay, timeZone) {
  let guess = Date.UTC(y, m - 1, d, Math.floor(minuteOfDay / 60), minuteOfDay % 60);
  for (let i = 0; i < 3; i++) {
    const z = zoned(guess, timeZone);
    const want = Date.UTC(y, m - 1, d) / MINUTE + minuteOfDay;
    const got = Date.UTC(z.y, z.m - 1, z.d) / MINUTE + z.minute;
    guess += (want - got) * MINUTE;
  }
  return guess;
}

function nextDue(r, now, timeZone) {
  const [y, m, d] = r.startDate.split("-").map(Number);
  const startDay = Date.UTC(y, m - 1, d) / DAY;
  const today = zoned(now, timeZone);
  const todayIndex = Date.UTC(today.y, today.m - 1, today.d) / DAY;
  for (let day = Math.max(startDay, todayIndex); day < Math.max(startDay, todayIndex) + 800; day++) {
    const date = new Date(day * DAY);
    const weekday = date.getUTCDay() + 1;
    const offset = day - startDay;
    const fits = r.unit === "days"
      ? offset % r.interval === 0
      : r.weekdays.includes(weekday) && Math.floor((offset + (new Date(startDay * DAY).getUTCDay())) / 7) % r.interval === 0;
    if (!fits) continue;
    const due = wallTime(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(), r.minuteOfDay, timeZone);
    if (due > now) return due;
  }
  return null;
}

function scheduleText(r, timeZone) {
  const time = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: "UTC" }).format(Date.UTC(2000, 0, 1, 0, r.minuteOfDay));
  void timeZone;
  if (r.unit === "days") return r.interval === 1 ? `Every day at ${time}` : `Every ${r.interval} days at ${time}`;
  const set = [...r.weekdays].sort();
  const names = set.map((w) => DAY_NAMES[w]);
  const list = set.length === 7 ? "every day" : set.join() === "2,3,4,5,6" ? "weekdays" : names.length <= 2 ? names.join(" and ") : names.slice(0, -1).join(", ") + " and " + names.at(-1);
  if (r.interval === 1) return set.length === 7 ? `Every day at ${time}` : set.join() === "2,3,4,5,6" ? `Every weekday at ${time}` : `Every ${list} at ${time}`;
  return `Every ${r.interval} weeks on ${list} at ${time}`;
}

// ---------------------------------------------------------------- demo data

function newTask({ id = lc.uuid(), title, course = null, details = "", due, created, source = "manual", repeatId = null }) {
  return { id, title, course, details, due, created, status: "pending", statusAt: null, penaltyEndsAt: null, source, repeatId, checking: false, proofs: [], extensions: [] };
}

function emptyModel() {
  return {
    tasks: [],
    repeats: [],
    apps: { builtIn: [], allowed: [], blocked: [], running: [], recent: [] },
    settings: { penaltyMinutes: 30, extensionsEnabled: true },
    access: { mode: "normal", until: null, strength: null, by: "", at: 0 },
    trackRecord: { onTime: 0, late: 0, missed: 0, extensionsThisWeek: 0 },
    message: null,
  };
}

/** A believable week for one student, relative to now. */
function seedModel(now, timeZone) {
  const today = zoned(now, timeZone);
  const at = (days, h, min = 0) => {
    const d = new Date(Date.UTC(today.y, today.m - 1, today.d + days));
    return wallTime(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), h * 60 + min, timeZone);
  };
  const quarter = (ms) => Math.floor(ms / (15 * MINUTE)) * 15 * MINUTE;
  const m = emptyModel();
  const piano = { id: lc.uuid(), title: "Practice piano, 30 minutes", details: "Scales first, then the recital piece.", unit: "weeks", interval: 1, weekdays: [2, 3, 4, 5, 6], minuteOfDay: 18 * 60, startDate: isoDate(today) };
  const desk = { id: lc.uuid(), title: "Clean up the desk", details: "", unit: "weeks", interval: 2, weekdays: [1], minuteOfDay: 10 * 60, startDate: isoDate(today) };
  const cards = { id: lc.uuid(), title: "French flashcards", details: "Unit 4 deck.", unit: "days", interval: 2, minuteOfDay: 19 * 60 + 30, weekdays: [], startDate: isoDate(today) };
  m.repeats = [piano, desk, cards];

  const worksheet = newTask({ title: "Worksheet 3.2: linear equations", course: "Math 8", details: "Problems 1 to 12. Show your work.", due: quarter(now - 2 * HOUR), created: now - 3 * DAY });
  worksheet.proofs.push({ id: lc.uuid(), at: worksheet.due - 25 * MINUTE, files: 1, note: "Problems 1 to 12. The second page is on the back.", verdict: "rejected", reason: "The photo shows problems 1 to 5 only; 6 to 12 aren't visible." });
  const lab = newTask({ title: "Lab report draft", course: "Science", details: "Include the graph of the cooling curve.", due: at(2, 21), created: now - 2 * DAY });
  lab.proofs.push({ id: lc.uuid(), at: now - 8 * MINUTE, files: 2, note: "Draft with both graphs.", verdict: null, reason: "" });
  lab.checking = true;
  const history = newTask({ title: "Reading notes, chapter 5", course: "History", due: at(-1, 21), created: now - 4 * DAY });
  history.proofs.push({ id: lc.uuid(), at: at(-1, 20, 12), files: 1, note: "", verdict: "accepted", reason: "The notes cover all five sections, with dates." });
  Object.assign(history, { status: "proven", statusAt: at(-1, 20, 13) });
  const spanish = newTask({ title: "Quiz corrections", course: "Spanish", due: at(-3, 8), created: now - 6 * DAY });
  spanish.proofs.push({ id: lc.uuid(), at: at(-3, 9, 40), files: 1, note: "Sorry, forgot it at school.", verdict: "accepted", reason: "All corrections are there." });
  Object.assign(spanish, { status: "provenLate", statusAt: at(-3, 9, 41), penaltyEndsAt: at(-3, 10, 11) });
  const form = newTask({ title: "Field trip form", details: "Signed by a parent.", due: at(-2, 8), created: now - 5 * DAY });
  Object.assign(form, { status: "excused", statusAt: at(-2, 7) });

  m.tasks = [
    worksheet,
    newTask({ title: "Read chapter 7 and write a summary", course: "English", details: "Half a page, in your own words.", due: at(1, 8), created: now - DAY }),
    newTask({ title: piano.title, details: piano.details, due: at(1, 18), created: now, source: "repeat", repeatId: piano.id }),
    lab,
    newTask({ title: "Vocabulary, unit 4", course: "French", due: at(4, 15, 30), created: now - DAY }),
    history,
    spanish,
    form,
  ];
  m.apps = {
    builtIn: [
      { id: "com.apple.iWork.Pages", name: "Pages" }, { id: "com.apple.iWork.Keynote", name: "Keynote" },
      { id: "com.apple.iWork.Numbers", name: "Numbers" }, { id: "com.apple.Notes", name: "Notes" },
      { id: "com.apple.Preview", name: "Preview" }, { id: "com.microsoft.Word", name: "Microsoft Word" },
      { id: "us.zoom.xos", name: "zoom.us" }, { id: "com.anthropic.claudefordesktop", name: "Claude" },
    ],
    allowed: [{ id: "com.spotify.client", name: "Spotify" }],
    blocked: [{ id: "com.valvesoftware.steam", name: "Steam" }],
    running: [
      { id: "company.thebrowser.Browser", name: "Arc" }, { id: "com.apple.iWork.Pages", name: "Pages" },
      { id: "com.spotify.client", name: "Spotify" }, { id: "com.hnc.Discord", name: "Discord" },
      { id: "com.apple.Notes", name: "Notes" }, { id: "com.apple.MobileSMS", name: "Messages" },
    ],
    recent: [
      { id: "com.roblox.RobloxPlayer", name: "Roblox", lastSeen: now - 3 * HOUR },
      { id: "com.apple.FaceTime", name: "FaceTime", lastSeen: now - 5 * HOUR },
      { id: "com.valvesoftware.steam", name: "Steam", lastSeen: now - DAY },
      { id: "com.mojang.minecraftlauncher", name: "Minecraft", lastSeen: now - 2 * DAY },
    ],
  };
  m.trackRecord = { onTime: 14, late: 2, missed: 1, extensionsThisWeek: 1 };
  return m;
}

function seedActivity(m, now) {
  const w = m.tasks[0];
  return [
    { at: now - DAY - 40 * MINUTE, kind: "verdict", text: "Claude accepted the proof for Reading notes, chapter 5" },
    { at: w.proofs[0].at, kind: "proof", text: `Sent a proof for ${w.title}` },
    { at: w.proofs[0].at + 2 * MINUTE, kind: "verdict", text: `Claude didn't accept the proof for ${w.title}` },
    { at: w.due, kind: "lock", text: `${w.title} is overdue: the computer locked` },
    { at: w.due + 25 * MINUTE, kind: "enforce", text: "Closed Discord during the lock" },
    { at: now - 8 * MINUTE, kind: "proof", text: "Sent a proof for Lab report draft" },
  ];
}

const isoDate = (z) => `${z.y}-${String(z.m).padStart(2, "0")}-${String(z.d).padStart(2, "0")}`;
/** The state without the parts that change on every upload. */
const stateFingerprint = (json) => json.replace(/"seq":\d+,"sentAt":\d+,/, "");

// ---------------------------------------------------------------- command line

async function main() {
  const args = process.argv.slice(2);
  const opt = (name, fallback) => {
    const i = args.indexOf("--" + name);
    return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : fallback;
  };
  const server = opt("server", "http://localhost:8787");
  const setupCode = opt("setup-code", process.env.TC_SETUP_CODE);
  if (!setupCode) {
    console.error("Pass the relay's setup code: --setup-code ABCD-EFGH-JKMN (see: node server/server.mjs --setup-code)");
    process.exit(2);
  }
  const fc = new FakeComputer({
    server, setupCode, name: opt("name", "Test Mac"), platform: opt("platform", "mac"), file: opt("file", null),
    seed: !args.includes("--no-seed"), log: (line) => console.log(`[${new Date().toLocaleTimeString()}] ${line}`),
  });
  await fc.init();
  for (let i = 0; i < args.length; i++) if (args[i] === "--flag" && args[i + 1]) fc.raiseFlag(args[i + 1], flagText(args[i + 1]));
  await fc.connect();
  console.log(`Linked as "${fc.name}" (${fc.devices.length} phone${fc.devices.length === 1 ? "" : "s"} paired).`);

  // --approve-delay N: wait N seconds before approving, like a parent typing the guardian code.
  const delay = Number(opt("approve-delay", 0)) * 1000;
  const approve = delay > 0 ? () => new Promise((resolve) => setTimeout(() => resolve(true), delay)) : undefined;
  const pair = async () => {
    const p = await fc.startPairing({ approve });
    console.log(`\nPairing code: ${p.formatted}   (valid 10 minutes)\nOr open: ${server}/#code=${p.code}\n`);
    p.result.then((r) => console.log(r.ok ? `Paired ${r.device.name}.` : `Pairing failed: ${r.why}`));
  };
  if (args.includes("--pair") || fc.devices.length === 0) await pair();

  const { createInterface } = await import("node:readline");
  const rl = createInterface({ input: process.stdin });
  rl.on("line", async (line) => {
    const [cmd, ...rest] = line.trim().split(/\s+/);
    try {
      if (cmd === "pair") await pair();
      else if (cmd === "sleep") await fc.sleep();
      else if (cmd === "wake") await fc.wake();
      else if (cmd === "overdue") (fc.addOverdueTask(), await fc.uploadState());
      else if (cmd === "proof") {
        const t = fc.model.tasks.find((x) => x.status === "pending");
        if (t) (fc.addProof(t.id), await fc.uploadState(), console.log("Added a proof to " + t.title));
      } else if (cmd === "flag") (fc.raiseFlag(rest[0], flagText(rest[0])), await fc.uploadState());
      else if (cmd === "unflag") (fc.clearFlags(), await fc.uploadState());
      else if (cmd === "reject") (fc.rejectNext = rest[0] || "bad_args"), console.log(`The next command will be rejected (${fc.rejectNext}).`);
      else if (cmd === "remove") {
        // Like the guardian pressing Remove next to a phone on the computer.
        const name = rest.join(" ");
        const before = fc.devices.length;
        fc.devices = fc.devices.filter((d) => d.name !== name);
        await fc.registerDevices();
        await fc.uploadState();
        console.log(before === fc.devices.length ? `No phone called ${name}.` : `Removed ${name}.`);
      }
      else if (cmd === "status") {
        const s = fc.buildState();
        console.log(`access=${s.access.mode} locked=${s.lock.locked} tasks=${s.tasks.length} phones=${s.devices.map((d) => d.name).join(", ") || "none"} results=${s.results.length}`);
      } else if (cmd === "quit") process.exit(0);
      else if (cmd) console.log("Commands: pair, sleep, wake, overdue, proof, flag <kind>, unflag, reject <reason>, remove <phone name>, status, quit");
    } catch (e) {
      console.log("Error: " + e.message);
    }
  });
  process.on("SIGINT", () => process.exit(0));
  await fc.run();
}

function flagText(kind) {
  return {
    testMode: "Tax Collector is in test mode: limited enforcement.",
    noBackgroundAgent: "The background helper is missing, so quitting the app ends enforcement.",
    guardianChanged: "The guardian code changed without a guardian action.",
    overrideMismatch: "The saved unlock time isn't the one the app wrote.",
    clockSkew: "The computer's clock is more than 2 minutes off.",
    gap: "Tax Collector wasn't running from 4:10 PM to 4:55 PM while the computer was awake.",
    linkRestored: "The link file was deleted and restored from the backup copy.",
    restarts: "Tax Collector was stopped and restarted 3 times today.",
    badCommand: "A command failed its check.",
  }[kind] ?? kind;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
