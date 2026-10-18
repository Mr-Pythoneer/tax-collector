// State uploads and reads (docs/parent-link-v1.md §5.2, §6.1) and liveness: what a parent's phone
// learns about the computer, and the ETag that keeps its polling cheap.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS } from "../lib/relay.mjs";
import { openRelay, call, setupChannel, newToken, channelId, deviceId, fakeBox, expectError, rawRequest, until } from "./helpers.mjs";

const putState = (r, s, seq, copies) => call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq, copies } });
const getState = (r, s, phone, headers) => call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: phone.token, headers });
const presence = (r, s, awake) => call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { token: s.computer.token, body: { awake } });
const pollNow = (r, s) => call(r.base, "GET", `/v1/ch/${s.ch}/cmd`, { token: s.computer.token });

/** The liveness headers of a GET state answer. */
const live = (res) => ({
  serverTime: Number(res.headers.get("x-tc-server-time")),
  computerSeen: Number(res.headers.get("x-tc-computer-seen")),
  computerAwake: res.headers.get("x-tc-computer-awake"),
});

test("GET state → 204 before any upload, with the liveness headers", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const seenAt = r.clock.now;
  r.clock.now += 3000;
  const res = await getState(r, s, s.phones[0]);
  assert.equal(res.status, 204);
  assert.equal(res.text, "");
  assert.deepEqual(live(res), { serverTime: r.clock.now, computerSeen: seenAt, computerAwake: "true" });
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(res.headers.get("etag"), null);
});

test("PUT state → 204; each phone reads its own copy, with exactly the fields of §6.1", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 2 });
  const [p1, p2] = s.phones;
  const box1 = fakeBox(200);
  const box2 = fakeBox(300);
  r.clock.now += 1000;
  const uploadedAt = r.clock.now;
  const put = await putState(r, s, 42, { [p1.id]: box1, [p2.id]: box2 });
  assert.equal(put.status, 204);
  assert.equal(put.text, "");
  r.clock.now += 2000;

  const res1 = await getState(r, s, p1);
  assert.equal(res1.status, 200);
  assert.deepEqual(res1.json, {
    seq: 42,
    box: box1,
    updatedAt: uploadedAt,
    serverTime: r.clock.now,
    computerSeen: uploadedAt,
    computerAwake: true,
    ackedUpTo: 0,
    lastCmdSeq: 0,
  });
  assert.deepEqual(live(res1), { serverTime: r.clock.now, computerSeen: uploadedAt, computerAwake: "true" });
  assert.equal(res1.headers.get("cache-control"), "no-store");

  const res2 = await getState(r, s, p2);
  assert.equal(res2.json.box, box2);
  assert.match(res1.headers.get("etag"), /^"[^"]+"$/);
  assert.notEqual(res1.headers.get("etag"), res2.headers.get("etag"), "each copy has its own ETag");
});

test("each upload replaces every copy: a phone left out of the new one gets 204", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 2 });
  const [p1, p2] = s.phones;
  assert.equal((await putState(r, s, 1, { [p1.id]: fakeBox(), [p2.id]: fakeBox() })).status, 204);
  const newer = fakeBox();
  assert.equal((await putState(r, s, 2, { [p1.id]: newer })).status, 204);
  const res = await getState(r, s, p1);
  assert.equal(res.json.seq, 2);
  assert.equal(res.json.box, newer);
  assert.equal((await getState(r, s, p2)).status, 204);
});

test("copies for devices that aren't registered are ignored, not kept for later", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p1] = s.phones;
  const stranger = { id: deviceId(), ...newToken() };
  const mine = fakeBox();
  assert.equal((await putState(r, s, 1, { [p1.id]: mine, [stranger.id]: fakeBox() })).status, 204);
  assert.equal((await getState(r, s, p1)).json.box, mine);
  const reg = await call(r.base, "PUT", `/v1/ch/${s.ch}/devices`, {
    token: s.computer.token,
    body: { devices: [p1, stranger].map((d) => ({ id: d.id, tokenHash: d.hash })) },
  });
  assert.equal(reg.status, 204);
  assert.equal((await getState(r, s, stranger)).status, 204);
});

test("seq must be a whole number; otherwise the relay passes on whatever seq it gets", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const copies = { [p.id]: fakeBox() };
  for (const seq of [undefined, -1, 1.5, "1", null, true, 2 ** 53, [1], { n: 1 }]) {
    expectError(await putState(r, s, seq, copies), 400, "bad_request");
  }
  const huge = await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: `{"seq":1e400,"copies":{}}` });
  expectError(huge, 400, "bad_request");
  assert.equal((await getState(r, s, p)).status, 204, "none of those stored anything");

  for (const seq of [0, 5, 3]) {
    assert.equal((await putState(r, s, seq, copies)).status, 204);
    // The phone, not the relay, ignores old news (§5.2).
    assert.equal((await getState(r, s, p)).json.seq, seq);
  }
});

test("copies must be an object keyed by device IDs, at most 8; a bad upload leaves the last state alone", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const kept = fakeBox();
  assert.equal((await putState(r, s, 1, { [p.id]: kept })).status, 204);
  const nine = Object.fromEntries(Array.from({ length: 9 }, () => [deviceId(), fakeBox()]));
  for (const copies of [undefined, null, [], [fakeBox()], "x", 7, { phone: fakeBox() }, { [p.id.toUpperCase()]: fakeBox() }, nine]) {
    expectError(await putState(r, s, 2, copies), 400, "bad_request");
  }
  const res = await getState(r, s, p);
  assert.equal(res.json.seq, 1);
  assert.equal(res.json.box, kept);
  assert.equal((await putState(r, s, 3, {})).status, 204, "an empty set of copies is allowed");
  assert.equal((await getState(r, s, p)).status, 204);
});

test("each copy may be at most stateCopyBytes (256 KB by default): one byte more → 413, and nothing changes", async (t) => {
  assert.equal(LIMITS.stateCopyBytes, 256 * 1024);
  const r = await openRelay(t, { limits: { stateCopyBytes: 1024 } });
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const fits = fakeBox(1024);
  assert.equal((await putState(r, s, 1, { [p.id]: fits })).status, 204);
  expectError(await putState(r, s, 2, { [p.id]: fakeBox(1025) }), 413, "too_large");
  // A copy for an unregistered device is still measured.
  expectError(await putState(r, s, 3, { [p.id]: fakeBox(40), [deviceId()]: fakeBox(1025) }), 413, "too_large");
  const res = await getState(r, s, p);
  assert.equal(res.json.seq, 1);
  assert.equal(res.json.box, fits);
});

test("with the default limits, a 200 KB copy is accepted", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const big = fakeBox(200 * 1024);
  assert.equal((await putState(r, s, 1, { [p.id]: big })).status, 204);
  assert.equal((await getState(r, s, p)).json.box, big);
});

test("a copy that isn't a sealed box (base64url of at least 28 bytes) is a bad request", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  for (const box of ["", "not base64!", fakeBox(27), fakeBox(40) + "=", 42, null, { box: fakeBox() }]) {
    expectError(await putState(r, s, 1, { [p.id]: box }), 400, "bad_request");
  }
  assert.equal((await putState(r, s, 1, { [p.id]: fakeBox(28) })).status, 204, "28 bytes is the smallest box");
});

test("a request body over 300 KB → 413, whether its length is declared up front or not", async (t) => {
  assert.equal(LIMITS.bodyBytes, 300 * 1024);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const headers = { authorization: "Bearer " + s.computer.token, "content-type": "application/json" };
  const path = `/v1/ch/${s.ch}/state`;

  // A declared length over the limit is refused before any of the body is read.
  const declared = await rawRequest(r.base, "PUT", path, {
    headers: { ...headers, "content-length": String(300 * 1024 + 1) },
    write: (req) => req.flushHeaders(),
  });
  expectError(declared, 413, "too_large");

  // A chunked body is cut off as soon as it passes the limit.
  const streamed = await rawRequest(r.base, "PUT", path, {
    headers,
    write: (req) => {
      req.write(`{"seq":1,"copies":{"${p.id}":"`);
      req.write("A".repeat(301 * 1024));
    },
  });
  expectError(streamed, 413, "too_large");

  assert.equal((await getState(r, s, p)).status, 204, "nothing was stored");
});

// ---------------------------------------------------------------- ETag

test("GET state's ETag: 304 while nothing changes; a new ETag when awake, lastCmdSeq, ackedUpTo or seq change", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  assert.equal((await putState(r, s, 1, { [p.id]: fakeBox() })).status, 204);
  const first = await getState(r, s, p);
  const e1 = first.headers.get("etag");
  const ifNoneMatch = (etag) => getState(r, s, p, { "if-none-match": etag });

  // Time passing and the computer checking in move serverTime and computerSeen, not the ETag.
  r.clock.now += 60_000;
  assert.equal((await pollNow(r, s)).status, 200);
  const checkedIn = r.clock.now;
  r.clock.now += 1000;
  const same = await ifNoneMatch(e1);
  assert.equal(same.status, 304);
  assert.equal(same.text, "");
  assert.equal(same.headers.get("etag"), e1);
  assert.equal(same.headers.get("cache-control"), "no-store");
  assert.deepEqual(live(same), { serverTime: r.clock.now, computerSeen: checkedIn, computerAwake: "true" });

  // Weak, listed and wildcard forms match too; another tag doesn't.
  assert.equal((await ifNoneMatch(`W/${e1}`)).status, 304);
  assert.equal((await ifNoneMatch(`"other", ${e1}`)).status, 304);
  assert.equal((await ifNoneMatch("*")).status, 304);
  assert.equal((await ifNoneMatch('"other"')).status, 200);

  const changes = [
    ["the computer goes to sleep", () => presence(r, s, false), (j) => assert.equal(j.computerAwake, false)],
    ["the computer is back", () => pollNow(r, s), (j) => assert.equal(j.computerAwake, true)],
    ["a command arrives", () => call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box: fakeBox() } }), (j) => assert.equal(j.lastCmdSeq, 1)],
    ["the computer acks it", () => call(r.base, "POST", `/v1/ch/${s.ch}/cmd/ack`, { token: s.computer.token, body: { upTo: 1 } }), (j) => assert.equal(j.ackedUpTo, 1)],
    ["a new state", () => putState(r, s, 2, { [p.id]: fakeBox() }), (j) => assert.equal(j.seq, 2)],
  ];
  let etag = e1;
  for (const [what, act, check] of changes) {
    const done = await act();
    assert.ok(done.status >= 200 && done.status < 300, what + ": " + done.status);
    const res = await ifNoneMatch(etag);
    assert.equal(res.status, 200, what);
    check(res.json);
    const next = res.headers.get("etag");
    assert.notEqual(next, etag, what);
    etag = next;
    assert.equal((await ifNoneMatch(etag)).status, 304, what + ", then nothing more");
  }
});

// ---------------------------------------------------------------- liveness

test("computerSeen is the time of the computer's latest request, whatever it was; others' requests don't count", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const slot = channelId();
  const token = s.computer.token;
  const requests = [
    ["PUT state", () => putState(r, s, 1, { [p.id]: fakeBox() })],
    ["PUT devices", () => call(r.base, "PUT", `/v1/ch/${s.ch}/devices`, { token, body: { devices: [{ id: p.id, tokenHash: p.hash }] } })],
    ["GET cmd", () => pollNow(r, s)],
    ["ack", () => call(r.base, "POST", `/v1/ch/${s.ch}/cmd/ack`, { token, body: { upTo: 0 } })],
    ["presence", () => presence(r, s, true)],
    ["PUT its channel again", () => call(r.base, "PUT", `/v1/channels/${s.ch}`, { token, body: { setupCode: r.relay.setupCode, tokenHash: s.computer.hash } })],
    ["PUT a pairing slot", () => call(r.base, "PUT", `/v1/pair/${slot}`, { token, body: { ch: s.ch, hello: fakeBox() } })],
    ["read toComputer", () => call(r.base, "GET", `/v1/pair/${slot}/toComputer`, { token })],
    ["write toPhone", () => call(r.base, "POST", `/v1/pair/${slot}/toPhone`, { token, body: { box: fakeBox() } })],
    ["DELETE the slot", () => call(r.base, "DELETE", `/v1/pair/${slot}`, { token })],
    ["a request with a bad body", () => presence(r, s, "yes")],
  ];
  for (const [what, send] of requests) {
    r.clock.now += 1000;
    const res = await send();
    assert.ok(res.status < 500, what + ": " + res.status);
    const st = await getState(r, s, p);
    assert.equal(st.status, 200, what);
    assert.equal(st.json.computerSeen, r.clock.now, what);
    assert.equal(live(st).computerSeen, r.clock.now, what);
  }

  const lastSeen = r.clock.now;
  r.clock.now += 1000;
  expectError(await call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { token: newToken().token, body: { awake: true } }), 401, "unauthorized");
  expectError(await call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { token: p.token, body: { awake: true } }), 401, "unauthorized");
  assert.equal((await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box: fakeBox() } })).status, 201);
  r.clock.now += 1000;
  const st = await getState(r, s, p);
  assert.equal(st.json.computerSeen, lastSeen);
  assert.equal(st.json.serverTime, r.clock.now);
});

test("presence false → computerAwake false until the computer's next request of any kind", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  assert.equal((await putState(r, s, 1, { [p.id]: fakeBox() })).status, 204);
  const awake = async () => {
    const res = await getState(r, s, p);
    assert.equal(live(res).computerAwake, String(res.json.computerAwake));
    return res.json.computerAwake;
  };
  assert.equal(await awake(), true);
  const asleep = await presence(r, s, false);
  assert.equal(asleep.status, 204);
  assert.equal(asleep.text, "");
  assert.equal(await awake(), false);
  assert.equal((await presence(r, s, true)).status, 204);
  assert.equal(await awake(), true);
  assert.equal((await presence(r, s, false)).status, 204);
  assert.equal(await awake(), false);
  assert.equal((await pollNow(r, s)).status, 200);
  assert.equal(await awake(), true);

  for (const value of [undefined, "false", 0, null, [false]]) {
    assert.equal((await presence(r, s, false)).status, 204);
    expectError(await presence(r, s, value), 400, "bad_request");
    assert.equal(await awake(), true, "even a refused request shows the computer is up");
  }
});

test("while the computer's long-poll is open, computerSeen is the server's time", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  assert.equal((await putState(r, s, 1, { [p.id]: fakeBox() })).status, 204);
  const poll = call(r.base, "GET", `/v1/ch/${s.ch}/cmd?wait=5`, { token: s.computer.token });
  await until(() => r.relay.waiters.count("cmd:" + s.ch) === 1, "the long-poll to wait");

  for (let i = 0; i < 2; i++) {
    r.clock.now += 90_000;
    const during = await getState(r, s, p);
    assert.equal(during.json.computerSeen, r.clock.now);
    assert.equal(during.json.serverTime, r.clock.now);
    assert.equal(live(during).computerSeen, r.clock.now);
  }

  assert.equal((await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box: fakeBox() } })).status, 201);
  assert.equal((await poll).status, 200);
  const answeredAt = r.clock.now;
  r.clock.now += 5000;
  const after = await getState(r, s, p);
  assert.equal(after.json.computerSeen, answeredAt, "once it's closed, the time it answered");
  assert.equal(after.json.serverTime, r.clock.now);
});
