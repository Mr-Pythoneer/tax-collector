// Timing cases found in review: a computer going to sleep while its long-poll is open, a
// channel removed while a request's body is still arriving, and request targets URL can't parse.
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { openRelay, call, setupChannel, newToken, fakeBox, expectError, rawRequest, until } from "./helpers.mjs";

const waiting = (r, ch) => r.relay.waiters.count("cmd:" + ch);
const getState = (r, s) => call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: s.phones[0].token });
const presence = (r, s, awake) => call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { token: s.computer.token, body: { awake } });

/** A long-poll the test can end from the client's side, as a Mac going to sleep might. */
function openPoll(r, s, wait) {
  const { hostname, port } = new URL(r.base);
  const req = http.request({ host: hostname, port, path: `/v1/ch/${s.ch}/cmd?wait=${wait}`, headers: { authorization: "Bearer " + s.computer.token }, agent: false });
  const done = new Promise((resolve) => {
    req.on("response", (res) => res.resume().on("end", () => resolve(res.statusCode)));
    req.on("error", () => resolve("gone"));
  });
  req.end();
  return { done, abort: () => req.destroy() };
}

test("going to sleep while the long-poll is open: the poll ending doesn't make the computer awake again", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq: 1, copies: { [s.phones[0].id]: fakeBox() } } });

  // The Mac leaves its poll open and says it's going to sleep.
  const poll = openPoll(r, s, 1);
  await until(() => waiting(r, s.ch) === 1, "the poll to wait");
  const sleptAt = r.clock.now;
  assert.equal((await presence(r, s, false)).status, 204);
  let st = await getState(r, s);
  assert.equal(st.json.computerAwake, false);
  assert.equal(st.json.computerSeen, sleptAt, "an open poll doesn't count as 'here now' once it said it's asleep");
  r.clock.now += 20_000;
  assert.equal(await poll.done, 200);
  st = await getState(r, s);
  assert.equal(st.json.computerAwake, false, "still asleep after the poll timed out");
  assert.equal(st.json.computerSeen, sleptAt, "last seen when it said goodbye");

  // The other order: the Mac drops its poll as it sleeps.
  assert.equal((await presence(r, s, true)).status, 204);
  const poll2 = openPoll(r, s, 5);
  await until(() => waiting(r, s.ch) === 1, "the second poll to wait");
  r.clock.now += 1000;
  assert.equal((await presence(r, s, false)).status, 204);
  const slept2 = r.clock.now;
  r.clock.now += 1000;
  poll2.abort();
  await poll2.done;
  await until(() => waiting(r, s.ch) === 0, "the poll to end");
  st = await getState(r, s);
  assert.equal(st.json.computerAwake, false);
  assert.equal(st.json.computerSeen, slept2);

  // Any new request from the computer means it's awake again.
  r.clock.now += 60_000;
  assert.equal((await call(r.base, "GET", `/v1/ch/${s.ch}/cmd`, { token: s.computer.token })).status, 200);
  st = await getState(r, s);
  assert.equal(st.json.computerAwake, true);
  assert.equal(st.json.computerSeen, r.clock.now);
});

test("a device list sent while the channel is being removed doesn't bring the channel back", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const body = JSON.stringify({ devices: [{ id: s.phones[0].id, tokenHash: s.phones[0].hash }] });
  // Start the upload, but hold back the last byte until the channel is gone.
  const late = rawRequest(r.base, "PUT", `/v1/ch/${s.ch}/devices`, {
    headers: { authorization: "Bearer " + s.computer.token, "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
    write: (req) => {
      req.write(body.slice(0, -1));
      setTimeout(async () => {
        await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token });
        req.end(body.slice(-1));
      }, 50);
    },
  });
  expectError(await late, 410, "gone", ["unlinkedAt"]);
  assert.equal(r.relay.channels.has(s.ch), false);
  await r.relay.store.flush();
  const files = (await readdir(join(r.dataDir, "channels"))).filter((n) => n.endsWith(".json"));
  assert.deepEqual(files, [], "no channel file came back");
});

test("a command sent while its channel is removed and made again isn't given to the new channel, and doesn't touch its files", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const p = s.phones[0];
  const body = JSON.stringify({ box: fakeBox(100) });
  const late = rawRequest(r.base, "POST", `/v1/ch/${s.ch}/cmd`, {
    headers: { authorization: "Bearer " + p.token, "content-type": "application/json", "content-length": String(Buffer.byteLength(body)) },
    write: (req) => {
      req.write(body.slice(0, -1));
      setTimeout(async () => {
        await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token });
        // The computer links again with the same channel ID, and queues nothing yet.
        await call(r.base, "PUT", `/v1/channels/${s.ch}`, { token: s.computer.token, body: { setupCode: r.relay.setupCode, tokenHash: s.computer.hash } });
        req.end(body.slice(-1));
      }, 50);
    },
  });
  expectError(await late, 401, "unauthorized"); // the new channel doesn't know that phone
  const c = r.relay.channels.get(s.ch);
  assert.equal(c.lastSeq, 0);
  assert.deepEqual(c.commands, []);
  await r.relay.store.flush();
  const names = await readdir(join(r.dataDir, "channels"));
  assert.ok(names.some((n) => n.endsWith(".commands.json")), "the new channel's commands file is still there");
  assert.ok(names.some((n) => /^[0-9a-f]{32}\.json$/.test(n)), "and its meta file");
});

test("request targets that URL can't parse get 400, and nothing is logged", async (t) => {
  const errors = [];
  const r = await openRelay(t);
  r.relay.log = { log() {}, warn() {}, error: (m) => errors.push(m) };
  for (const target of ["//[", "//a:b/x", "//%/x", "http://["]) {
    const res = await rawRequest(r.base, "GET", target);
    assert.equal(res.status, 400, target);
    assert.ok(res.headers.get("x-tc-instance"), "it still carries the instance");
  }
  assert.deepEqual(errors, []);
});

test("unexpected errors are logged at most 10 times a minute", async (t) => {
  const errors = [];
  const r = await openRelay(t);
  r.relay.log = { log() {}, warn() {}, error: (m) => errors.push(m) };
  const boom = new Error("boom");
  // Make every health check fail as if the server had a bug.
  r.relay.limiters.unauthenticated.take = () => {
    throw boom;
  };
  for (let i = 0; i < 25; i++) {
    const res = await call(r.base, "GET", "/v1/health", { ip: "10.0.0." + i });
    assert.equal(res.status, 500);
  }
  assert.equal(errors.length, 10);
});

test("the relay answers its own computer's re-link with 200 even after the setup code changes", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  r.relay.setupCode = "ZZZZZZZZZZZZ"; // as if TC_SETUP_CODE pinned a new one
  const again = await call(r.base, "PUT", `/v1/channels/${s.ch}`, { token: s.computer.token, body: { setupCode: "old code", tokenHash: s.computer.hash } });
  assert.equal(again.status, 200);
  const stranger = newToken();
  expectError(await call(r.base, "PUT", `/v1/channels/${s.ch}`, { token: stranger.token, body: { setupCode: "old code", tokenHash: stranger.hash } }), 403, "forbidden");
});
