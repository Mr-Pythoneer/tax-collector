// Shared test helpers: an in-process relay on a free port with a clock the test controls.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import http from "node:http";
import assert from "node:assert/strict";
import { Relay } from "../lib/relay.mjs";

export const quiet = { log() {}, warn() {}, error() {} };
export const PARENT_DIR = fileURLToPath(new URL("../../parent/", import.meta.url));

export const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
export const channelId = () => b64(randomBytes(16));
export const deviceId = () => globalThis.crypto.randomUUID();

/** A token and the hash the server keeps. */
export function newToken() {
  const bytes = randomBytes(32);
  return { token: b64(bytes), hash: b64(createHash("sha256").update(bytes).digest()) };
}

/** A box-shaped string: the relay only checks it's base64url of 28+ bytes. */
export const fakeBox = (n = 64) => b64(randomBytes(n));

/**
 * Starts a relay. `clock.now` is the relay's time; move it to test expiry. Pass the same
 * `dataDir` to a second relay to test what survives a restart.
 */
export async function startRelay({ dataDir, start = 1_800_000_000_000, realClock = false, limits, staticRoot, port = 0, trustProxy = true } = {}) {
  dataDir ??= await mkdtemp(join(tmpdir(), "tc-relay-test-"));
  const clock = { now: start };
  const relay = await Relay.open({ dataDir, now: realClock ? Date.now : () => clock.now, log: quiet, limits, staticRoot, trustProxy });
  const server = relay.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    relay,
    server,
    base,
    dataDir,
    clock,
    port: server.address().port,
    async stop() {
      await relay.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

/** One HTTP call. Returns { status, headers, json, text }. */
export async function call(base, method, path, { token, body, headers = {}, ip } = {}) {
  const h = { ...headers };
  if (token) h.authorization = "Bearer " + token;
  if (ip) h["x-forwarded-for"] = ip;
  if (body !== undefined) h["content-type"] = "application/json";
  const res = await fetch(base + path, {
    method,
    headers: h,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // not JSON: static files
  }
  return { status: res.status, headers: res.headers, json, text };
}

/** Creates a channel and registers devices. Returns everything a test needs to talk as either side. */
export async function setupChannel(r, { devices = 1 } = {}) {
  const ch = channelId();
  const computer = newToken();
  const created = await call(r.base, "PUT", `/v1/channels/${ch}`, {
    token: computer.token,
    body: { setupCode: r.relay.setupCode, tokenHash: computer.hash },
  });
  if (created.status !== 201) throw new Error("channel: " + created.status + " " + created.text);
  const phones = Array.from({ length: devices }, () => ({ id: deviceId(), ...newToken() }));
  const reg = await call(r.base, "PUT", `/v1/ch/${ch}/devices`, {
    token: computer.token,
    body: { devices: phones.map((p) => ({ id: p.id, tokenHash: p.hash })) },
  });
  if (reg.status !== 204) throw new Error("devices: " + reg.status + " " + reg.text);
  return { ch, computer, phones };
}

// ---------------------------------------------------------------- for the API tests

/** Starts a relay for one test; stops it and deletes its data folder when the test ends. */
export async function openRelay(t, options) {
  const r = await startRelay(options);
  t.after(async () => {
    await r.stop();
    await rm(r.dataDir, { recursive: true, force: true });
  });
  return r;
}

let ipCount = 0;
/** A new fake client address on every call, so requests don't share rate-limit buckets. */
export function fakeIp() {
  ipCount++;
  return `10.${(ipCount >> 16) & 255}.${(ipCount >> 8) & 255}.${ipCount & 255}`;
}

/** Polls until `check()` is true, e.g. until a long-poll is waiting on the relay. */
export async function until(check, what = "the condition", timeoutMs = 3000) {
  const end = Date.now() + timeoutMs;
  while (!(await check())) {
    if (Date.now() > end) throw new Error("Timed out waiting for " + what);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Asserts an API error: the status, its code, and a body of exactly {error, message, ...extraKeys}. */
export function expectError(res, status, code, extraKeys = []) {
  assert.ok(!res.error, `expected ${status} ${code}, got no answer: ${res.error?.message}`);
  assert.equal(res.status, status, `expected ${status} ${code}, got ${res.status}: ${res.text}`);
  assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(res.json?.error, code, res.text);
  assert.equal(typeof res.json.message, "string");
  assert.ok(res.json.message.length > 0, "an error has a message");
  assert.deepEqual(Object.keys(res.json).sort(), ["error", "message", ...extraKeys].sort());
}

/**
 * One HTTP request sent exactly as written: fetch tidies paths like "/../x" before sending, and
 * always sends a whole body with its length. `write(req)` may write some of a body (or none, after
 * req.flushHeaders()) and need not end it; without it the request is sent with no body. Resolves
 * to the same shape as call(), or to { error } if the connection fails or no answer comes in time.
 */
export function rawRequest(base, method, path, { headers = {}, write, timeoutMs = 10_000 } = {}) {
  const { hostname, port } = new URL(base);
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      req.destroy();
      resolve(result);
    };
    const timer = setTimeout(() => finish({ error: new Error(`no answer within ${timeoutMs} ms`) }), timeoutMs);
    const req = http.request({ host: hostname, port, method, path, headers, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("error", (error) => finish({ error }));
      res.on("end", () => {
        const body = Buffer.concat(chunks);
        const text = body.toString("utf8");
        let json = null;
        try {
          json = text ? JSON.parse(text) : null;
        } catch {
          // not JSON: static files
        }
        const h = new Headers();
        for (const [name, value] of Object.entries(res.headers)) h.append(name, Array.isArray(value) ? value.join(", ") : value);
        finish({ status: res.statusCode, headers: h, json, text, body });
      });
    });
    req.on("error", (error) => finish({ error }));
    if (write) write(req);
    else req.end();
  });
}
