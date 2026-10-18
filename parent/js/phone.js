// The phone's side of the parent link (docs/parent-link-v1.md §4 and §5): pairing, sending
// commands and reading state. It keeps nothing itself; callers pass a store for the counter,
// so the parent app (IndexedDB) and the fake phone (memory) run exactly this code.
import * as lc from "./linkcrypto.js";

export const PAIR_MS = 10 * 60 * 1000;
export const MAX_STATE_BYTES = 8 * 1024 * 1024;
export const DEVICE_NAME_MAX = 40;

export class LinkError extends Error {
  /** `code`: network, bad_code, expired, rejected, rate_limited, unauthorized, forbidden, gone, too_large, server, protocol. */
  constructor(code, message, extra = {}) {
    super(message);
    this.code = code;
    Object.assign(this, extra);
  }
}

const isId16 = (s) => {
  try {
    return typeof s === "string" && s.length === 22 && lc.unb64(s).length === 16;
  } catch {
    return false;
  }
};
export const isDeviceId = (s) => typeof s === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s);
const sleep = (ms, signal) =>
  new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => (clearTimeout(t), resolve()), { once: true });
  });

/** No line breaks, no more than 40 characters: the computer trims names the same way. */
export function cleanDeviceName(name) {
  const flat = String(name ?? "").replace(/[\n\r\u2028\u2029\u0085\u000b\u000c]/g, " ").trim();
  return [...flat].slice(0, DEVICE_NAME_MAX).join("").trim();
}

/**
 * One call to the relay. Never throws for HTTP errors; throws LinkError("network") if it can't
 * connect or gets no answer within `timeout` ms, and LinkError("aborted") if `signal` stops it.
 */
export async function request(origin, method, path, { token, body, headers = {}, signal, timeout = 20_000 } = {}) {
  const h = { ...headers };
  if (token) h.Authorization = "Bearer " + token;
  if (body !== undefined) h["Content-Type"] = "application/json";
  // AbortSignal.any isn't on every phone yet, so link the caller's signal and a timer by hand.
  const stop = new AbortController();
  const onAbort = () => stop.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => stop.abort(), timeout);
  let res;
  try {
    res = await fetch(origin + path, {
      method,
      headers: h,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
      credentials: "omit",
      signal: stop.signal,
    });
  } catch (e) {
    if (signal?.aborted) throw new LinkError("aborted", "Stopped");
    throw new LinkError("network", stop.signal.aborted ? "The server didn't answer in time." : "Can't reach the server.", { cause: e });
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
  }
  let json = null;
  if (res.status !== 204 && res.status !== 304) {
    const text = await res.text().catch(() => "");
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
  }
  return { status: res.status, json, headers: res.headers, instance: res.headers.get("X-TC-Instance") };
}

/** Turns an unexpected answer into a LinkError a parent can read. */
export function httpError(res, what = "The server") {
  const s = res.status;
  if (s === 401) return new LinkError("unauthorized", "This phone isn't connected to that computer any more.", { status: s });
  if (s === 403) return new LinkError("forbidden", "This phone belongs to another computer on the server.", { status: s });
  if (s === 410) return new LinkError("gone", "The computer was unlinked from the server.", { status: s, unlinkedAt: res.json?.unlinkedAt });
  if (s === 413) return new LinkError("too_large", "That was too large to send.", { status: s });
  if (s === 429) return new LinkError("rate_limited", "Too many tries. Wait a minute and try again.", { status: s });
  return new LinkError("server", `${what} answered ${s}.`, { status: s });
}

// ---------------------------------------------------------------- pairing (§4.2)

/**
 * Pairs this phone with a computer. `onStep` hears { step: "lookup" | "hello" | "commit" |
 * "compare" , computerName, comparison }. Returns the record to keep: keys stay CryptoKeys,
 * and the link key and signing key can't be exported.
 */
export async function pair({ origin, code, deviceName, onStep = () => {}, signal, now = Date.now }) {
  const name = cleanDeviceName(deviceName);
  if (!name) throw new LinkError("protocol", "Give this phone a name first.");
  let secrets;
  try {
    secrets = await lc.pairingSecrets(code);
  } catch {
    throw new LinkError("bad_code", "A pairing code has 10 letters and numbers, like ABCDE-FGHJK.");
  }
  const { slot, pairKey } = secrets;
  const deadline = now() + PAIR_MS;
  const base = `/v1/pair/${slot}`;

  onStep({ step: "lookup" });
  const found = await request(origin, "GET", base, { signal });
  if (found.status === 404) throw new LinkError("bad_code", "That code didn't work. Check it, or make a new one on the computer.");
  if (found.status !== 200) throw httpError(found);
  let hello;
  try {
    hello = await lc.openPairing(pairKey, slot, found.json?.hello);
  } catch {
    throw new LinkError("bad_code", "That code didn't work. Check it, or make a new one on the computer.");
  }
  let computerDhPub;
  try {
    computerDhPub = lc.unb64(hello.dhKey);
  } catch {
    computerDhPub = null;
  }
  if (hello.t !== "hello" || hello.v !== 1 || !isId16(hello.ch) || typeof hello.name !== "string" || computerDhPub?.length !== 65 || computerDhPub[0] !== 4) {
    throw new LinkError("protocol", "The computer's answer didn't make sense. Start again on the computer.");
  }
  const computerName = String(hello.name).replace(/[\n\r]/g, " ").slice(0, 100) || "The computer";
  const platform = hello.platform === "windows" ? "windows" : "mac";
  onStep({ step: "hello", computerName, platform });

  // Step 2: make the keys, then send only a commitment to them.
  const signing = await lc.newSigningKeys();
  const dh = await lc.newDhKeys();
  const phoneNonce = lc.randomBytes(32);
  const deviceToken = lc.randomBytes(32);
  const tokenHash = await lc.sha256(deviceToken);
  const commit = await lc.commitment({ signPub: signing.publicRaw, dhPub: dh.publicRaw, nonce: phoneNonce, tokenHash, name });
  await postPairMessage(origin, slot, pairKey, { t: "commit", commit }, signal);
  onStep({ step: "commit", computerName });

  // Step 3: the computer's nonce, which it sends only after it has our commitment.
  const cursor = { after: 0 };
  const nonceMsg = await nextPairMessage(origin, slot, pairKey, cursor, deadline, signal, now);
  if (nonceMsg.t !== "nonce") throw new LinkError("protocol", "The computer's answer didn't make sense. Start again on the computer.");
  let computerNonce;
  try {
    computerNonce = lc.unb64(nonceMsg.nonce);
  } catch {
    computerNonce = null;
  }
  if (computerNonce?.length !== 32) throw new LinkError("protocol", "The computer's answer didn't make sense. Start again on the computer.");

  // Step 4: reveal. Step 5: both screens show the comparison code.
  await postPairMessage(origin, slot, pairKey, {
    t: "reveal",
    signKey: lc.b64(signing.publicRaw),
    dhKey: lc.b64(dh.publicRaw),
    nonce: lc.b64(phoneNonce),
    tokenHash: lc.b64(tokenHash),
    name,
  }, signal);
  const comparison = await lc.comparisonCode({ computerNonce, phoneNonce, computerDhPub, phoneSignPub: signing.publicRaw, phoneDhPub: dh.publicRaw });
  onStep({ step: "compare", computerName, comparison });

  // Step 6: the parent at the computer compares and types the guardian code.
  const final = await nextPairMessage(origin, slot, pairKey, cursor, deadline, signal, now);
  if (final.t !== "done" || !isDeviceId(final.dev)) throw new LinkError("protocol", "The computer's answer didn't make sense. Start again on the computer.");
  const shared = await lc.ecdh(dh.privateKey, computerDhPub);
  const linkKey = await lc.deriveLinkKey(shared, hello.ch, final.dev);
  shared.fill(0);
  return {
    id: hello.ch + "." + final.dev,
    origin,
    channel: hello.ch,
    deviceId: final.dev,
    deviceToken: lc.b64(deviceToken),
    deviceName: name,
    computerName,
    platform,
    computerDhPublic: hello.dhKey,
    linkKey,
    signKey: signing.privateKey,
    signPublic: lc.b64(signing.publicRaw),
    dhKey: dh.privateKey,
    pairedAt: now(),
    instance: found.instance,
  };
}

async function postPairMessage(origin, slot, pairKey, message, signal) {
  const box = await lc.sealPairing(pairKey, slot, message);
  const res = await request(origin, "POST", `/v1/pair/${slot}/toComputer`, { body: { box }, signal });
  if (res.status === 404) throw new LinkError("expired", "The code ran out or was cancelled on the computer. Start again.");
  if (res.status === 409) throw new LinkError("rejected", "Two phones tried to pair at once. Start again.");
  if (res.status !== 201) throw httpError(res);
}

/** Waits for the computer's next message. A "rejected" message ends pairing with its reason. */
async function nextPairMessage(origin, slot, pairKey, cursor, deadline, signal, now) {
  let failures = 0;
  while (now() < deadline) {
    if (signal?.aborted) throw new LinkError("aborted", "Stopped");
    let res;
    const asked = Date.now();
    try {
      res = await request(origin, "GET", `/v1/pair/${slot}/toPhone?after=${cursor.after}&wait=25`, { signal, timeout: 40_000 });
    } catch (e) {
      if (e.code !== "network" || ++failures > 20) throw e;
      await sleep(Math.min(5000, 500 * failures), signal);
      continue;
    }
    failures = 0;
    if (res.status === 404) throw new LinkError("expired", "The code ran out or was cancelled on the computer. Start again.");
    if (res.status === 429) {
      await sleep(5000, signal);
      continue;
    }
    if (res.status !== 200) throw httpError(res);
    // An empty answer that came back at once (not after waiting) shouldn't make us ask again at once.
    if (!res.json?.messages?.length && Date.now() - asked < 1000) await sleep(1000, signal);
    for (const m of res.json?.messages ?? []) {
      cursor.after = Math.max(cursor.after, m.n);
      let msg;
      try {
        msg = await lc.openPairing(pairKey, slot, m.box);
      } catch {
        continue; // not sealed with this code's key: not from the computer
      }
      if (msg.t === "rejected") {
        const why = typeof msg.why === "string" && msg.why.trim() ? msg.why.replace(/[\n\r]/g, " ").slice(0, 200) : "The computer stopped the pairing. Start again.";
        throw new LinkError("rejected", why);
      }
      return msg;
    }
  }
  throw new LinkError("expired", "The code ran out. Start again on the computer.");
}

// ---------------------------------------------------------------- commands (§5.1)

const localLocks = new Map();
/** One command at a time per device: navigator.locks across tabs, a promise chain otherwise. */
export function withLock(name, fn) {
  const locks = globalThis.navigator?.locks;
  if (locks?.request) return locks.request(name, fn);
  const prev = localLocks.get(name) ?? Promise.resolve();
  const run = prev.then(fn, fn);
  localLocks.set(name, run.catch(() => {}));
  return run;
}

/**
 * Signs, seals and sends one command. `store.getCounter(id)` / `store.setCounter(id, n)` keep
 * the counter: n = max(previous n + 1, now in ms), saved before sending so it's never reused.
 * Returns { id, n, at, type, args, seq, receivedAt }. `at` and `n` may be set by tests.
 */
export function sendCommand({ computer, store, type, args, now = Date.now, at, n: forcedN, id = lc.uuid(), signal }) {
  return withLock("tc-cmd-" + computer.id, async () => {
    const t = now();
    const previous = (await store.getCounter(computer.id)) ?? 0;
    const n = forcedN ?? Math.max(previous + 1, t);
    if (forcedN === undefined) await store.setCounter(computer.id, n);
    const issuedAt = at ?? t;
    const body = lc.commandBody({ channel: computer.channel, deviceId: computer.deviceId, n, at: issuedAt, id, type, args });
    const box = await lc.sealCommand({ linkKey: computer.linkKey, signKey: computer.signKey, channel: computer.channel, deviceId: computer.deviceId, body });
    let res;
    try {
      res = await postCommand(computer, box, signal);
    } catch (e) {
      // The relay may have it even so (the answer was lost, or it failed after queueing it): keep
      // the sealed box, so it can be sent again, which is safe, and matched to its result.
      Object.assign(e, { box, n, at: issuedAt });
      throw e;
    }
    return { id, n, at: issuedAt, type, args, seq: res.json.seq, receivedAt: res.json.receivedAt, box, instance: res.instance };
  });
}

/** True when a send failed in a way that may still have reached the relay. */
export const maybeSent = (e) => e?.code === "network" || (e?.code === "server" && e.status >= 500);

/** Sends a sealed command, trying again on network errors. Resending the same box is safe. */
export async function postCommand(computer, box, signal) {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await request(computer.origin, "POST", `/v1/ch/${computer.channel}/cmd`, { token: computer.deviceToken, body: { box }, signal });
      if (res.status === 201 && Number.isSafeInteger(res.json?.seq)) return res;
      throw httpError(res);
    } catch (e) {
      if (e.code !== "network" || attempt >= 2) throw e;
      await sleep(800 * (attempt + 1), signal);
    }
  }
}

// ---------------------------------------------------------------- state (§5.2)

const num = (v) => (v === null || v === undefined || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));

/**
 * Fetches this phone's copy of the state. Returns one of:
 *  { kind: "state", state, etag, meta, live }  a newer document
 *  { kind: "same", live }                       nothing changed (304)
 *  { kind: "old", live, seq }                   a document older than one already shown: ignored
 *  { kind: "empty", live }                      no state yet (204)
 *  { kind: "unopenable", live }                 the box didn't open: a tamper warning
 *  { kind: "unauthorized" | "forbidden", instance }
 *  { kind: "gone", unlinkedAt }
 * `live` is { serverTime, computerSeen, computerAwake, instance }.
 */
export async function fetchState({ computer, etag, lastSeq = -1, signal }) {
  const res = await request(computer.origin, "GET", `/v1/ch/${computer.channel}/state`, {
    token: computer.deviceToken,
    headers: etag ? { "If-None-Match": etag } : {},
    signal,
    timeout: 15_000,
  });
  const live = {
    serverTime: num(res.headers.get("X-TC-Server-Time")),
    computerSeen: num(res.headers.get("X-TC-Computer-Seen")),
    computerAwake: res.headers.get("X-TC-Computer-Awake") === null ? null : res.headers.get("X-TC-Computer-Awake") === "true",
    instance: res.instance,
  };
  if (res.status === 304) return { kind: "same", live };
  if (res.status === 204) return { kind: "empty", live };
  if (res.status === 401) return { kind: "unauthorized", instance: res.instance };
  if (res.status === 403) return { kind: "forbidden", instance: res.instance };
  if (res.status === 410) return { kind: "gone", unlinkedAt: num(res.json?.unlinkedAt), instance: res.instance };
  if (res.status !== 200 || typeof res.json?.box !== "string") throw httpError(res);
  const j = res.json;
  live.serverTime = num(j.serverTime) ?? live.serverTime;
  live.computerSeen = num(j.computerSeen) ?? live.computerSeen;
  if (typeof j.computerAwake === "boolean") live.computerAwake = j.computerAwake;
  const meta = { seq: num(j.seq), updatedAt: num(j.updatedAt), ackedUpTo: num(j.ackedUpTo) ?? 0, lastCmdSeq: num(j.lastCmdSeq) ?? 0 };
  let state;
  try {
    state = await lc.openState({ linkKey: computer.linkKey, channel: computer.channel, deviceId: computer.deviceId, box: j.box, maxBytes: MAX_STATE_BYTES });
  } catch {
    return { kind: "unopenable", live, meta };
  }
  if (!state || typeof state !== "object" || state.v !== 1 || !Number.isSafeInteger(state.seq)) return { kind: "unopenable", live, meta };
  // The seq inside the sealed document is the one that counts: the server can't change it.
  if (state.seq < lastSeq) return { kind: "old", live, meta, seq: state.seq };
  return { kind: "state", state, etag: res.headers.get("ETag"), meta, live };
}

// ---------------------------------------------------------------- results (§5.3)

/**
 * A "replayed" result carries "last", the last counter the computer accepted from this phone.
 * If this phone's counter is behind it (restored from a backup, say), catch up so the next
 * command isn't refused too. Returns true if the counter moved.
 */
export async function catchUpCounter(state, computer, store, now = Date.now) {
  let last = 0;
  const ceiling = now() + 86_400_000; // a counter is a time in ms: anything past tomorrow is nonsense
  for (const r of state?.results ?? []) {
    if (r?.dev === computer.deviceId && r.reason === "replayed" && Number.isSafeInteger(r.last) && r.last <= ceiling) last = Math.max(last, r.last);
  }
  if (!last) return false;
  // Under the same lock as sending, so it can't undo a counter a command just saved.
  return withLock("tc-cmd-" + computer.id, async () => {
    const current = (await store.getCounter(computer.id)) ?? 0;
    if (last <= current) return false;
    await store.setCounter(computer.id, last);
    return true;
  });
}

const RANK = { applied: 4, noop: 3, unsupported: 2, rejected: 1 };

/** This device's result for a command ID, if the state has one. A resend's "replayed" never hides the real answer. */
export function resultFor(state, deviceId, commandId) {
  let best = null;
  for (const r of state?.results ?? []) {
    if (r?.id !== commandId || r.dev !== deviceId) continue;
    const score = (RANK[r.outcome] ?? 0) * 2 - (r.reason === "replayed" ? 1 : 0);
    if (!best || score > best.score) best = { score, outcome: r.outcome, reason: r.reason ?? "", at: r.at };
  }
  return best && { outcome: best.outcome, reason: best.reason, at: best.at };
}

/**
 * Where a sent command is now: "sending", "unconfirmed" (the send failed in a way that may
 * still have reached the relay), "failed", "waiting" (on the server, computer awake), "asleep"
 * (on the server, computer asleep or not heard from), "lost" (the server lost its data before
 * the computer took it), "delivered" (the computer took it), or the computer's outcome:
 * "applied", "noop", "rejected", "unsupported".
 */
export function commandPhase(cmd, { state, meta, live, deviceId }) {
  const result = resultFor(state, deviceId, cmd.id);
  if (result) return { phase: result.outcome, reason: result.reason };
  if (cmd.final) return { phase: cmd.final.outcome, reason: cmd.final.reason };
  if (!cmd.seq) return { phase: cmd.error ? (cmd.box ? "unconfirmed" : "failed") : "sending", reason: cmd.error ?? "" };
  // Seqs start again on a server that lost its data, so another instance's acks say nothing.
  if (cmd.instance && live?.instance && live.instance !== cmd.instance) return { phase: "lost", reason: "" };
  if (meta && meta.ackedUpTo >= cmd.seq) return { phase: "delivered", reason: "" };
  const quiet = live?.serverTime != null && live?.computerSeen != null && live.serverTime - live.computerSeen > 90_000;
  if (live?.computerAwake === false || quiet) return { phase: "asleep", reason: "" };
  return { phase: "waiting", reason: "" };
}
