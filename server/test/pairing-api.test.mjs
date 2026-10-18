// The relay's side of pairing (docs/parent-link-v1.md §4.2, §6.1): slots, the hello, and the two
// message directions. The relay can't open any of it; it only keeps slots apart and short-lived.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS } from "../lib/relay.mjs";
import { openRelay, call, setupChannel, newToken, channelId, fakeBox, fakeIp, expectError, until } from "./helpers.mjs";

const MINUTE = 60_000;
const slotId = channelId; // the same shape: 16 random bytes in base64url

// Calls without a computer token come from a new address each time, so the lookup limits of
// §6.3 (tested in limits.test.mjs) stay out of the way here.
const putSlot = (r, s, slot, hello = fakeBox(), token = s.computer.token) => call(r.base, "PUT", `/v1/pair/${slot}`, { token, body: { ch: s.ch, hello } });
const getSlot = (r, slot) => call(r.base, "GET", `/v1/pair/${slot}`, { ip: fakeIp() });
const deleteSlot = (r, slot, token) => call(r.base, "DELETE", `/v1/pair/${slot}`, { token, ip: fakeIp() });
const toComputer = (r, slot, box = fakeBox()) => call(r.base, "POST", `/v1/pair/${slot}/toComputer`, { body: { box }, ip: fakeIp() });
const toPhone = (r, slot, token, box = fakeBox()) => call(r.base, "POST", `/v1/pair/${slot}/toPhone`, { token, body: { box }, ip: fakeIp() });
const readToComputer = (r, slot, token, query = "") => call(r.base, "GET", `/v1/pair/${slot}/toComputer${query}`, { token, ip: fakeIp() });
const readToPhone = (r, slot, query = "") => call(r.base, "GET", `/v1/pair/${slot}/toPhone${query}`, { ip: fakeIp() });
const waiting = (r, slot, direction) => r.relay.waiters.count(`pair:${slot}:${direction}`);

/** Boxes a pairing message may not carry (`undefined` leaves "box" out of the body). */
const BAD_BOXES = [undefined, "", "not base64!", 42, null, fakeBox(27)];
const BIG_BOX = fakeBox(4097);
/** POSTs exactly this box, with no default standing in for a missing one. */
const postBox = (r, slot, direction, box, token) => call(r.base, "POST", `/v1/pair/${slot}/${direction}`, { token, body: { box }, ip: fakeIp() });

test("PUT /v1/pair/{slot} → 201 {expiresAt}; anyone can GET the hello; unknown slots → 404", async (t) => {
  assert.equal(LIMITS.pairSlotMs, 10 * MINUTE);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  const hello = fakeBox(500);
  const put = await putSlot(r, s, slot, hello);
  assert.equal(put.status, 201);
  assert.deepEqual(put.json, { expiresAt: r.clock.now + 10 * MINUTE });
  const got = await getSlot(r, slot);
  assert.equal(got.status, 200);
  assert.deepEqual(got.json, { hello });
  expectError(await getSlot(r, slotId()), 404, "not_found");
  for (const bad of ["short", slot + "A", slot.slice(0, 21) + "="]) {
    expectError(await getSlot(r, bad), 400, "bad_request");
    expectError(await putSlot(r, s, bad), 400, "bad_request");
  }
});

test("PUT slot needs the token that owns ch: 401 for any other, 404 for an unknown channel, 410 for an unlinked one", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  for (const token of [undefined, newToken().token, a.phones[0].token, b.computer.token]) {
    expectError(await call(r.base, "PUT", `/v1/pair/${slot}`, { token, body: { ch: a.ch, hello: fakeBox() }, ip: fakeIp() }), 401, "unauthorized");
  }
  expectError(await call(r.base, "PUT", `/v1/pair/${slot}`, { token: a.computer.token, body: { ch: channelId(), hello: fakeBox() } }), 404, "not_found");
  expectError(await getSlot(r, slot), 404, "not_found");

  assert.equal((await call(r.base, "DELETE", `/v1/channels/${b.ch}`, { token: b.computer.token })).status, 204);
  expectError(await putSlot(r, b, slotId()), 410, "gone", ["unlinkedAt"]);
});

test("PUT slot: ch must be a channel ID (400) and hello a box (400) of at most 4 KB (413)", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  for (const ch of [undefined, "", "abc", 42]) {
    expectError(await call(r.base, "PUT", `/v1/pair/${slot}`, { token: s.computer.token, body: { ch, hello: fakeBox() } }), 400, "bad_request");
  }
  for (const hello of BAD_BOXES) {
    expectError(await call(r.base, "PUT", `/v1/pair/${slot}`, { token: s.computer.token, body: { ch: s.ch, hello } }), 400, "bad_request");
  }
  expectError(await call(r.base, "PUT", `/v1/pair/${slot}`, { token: s.computer.token, body: { ch: s.ch, hello: BIG_BOX } }), 413, "too_large");
  expectError(await getSlot(r, slot), 404, "not_found");
  assert.equal((await putSlot(r, s, slot, fakeBox(4096))).status, 201, "exactly 4 KB fits");
});

test("a slot another channel holds → 409; its own channel may replace it; once it has expired anyone may take it", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 0 });
  const b = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  const helloA = fakeBox();
  assert.equal((await putSlot(r, a, slot, helloA)).status, 201);
  expectError(await putSlot(r, b, slot), 409, "conflict");
  assert.deepEqual((await getSlot(r, slot)).json, { hello: helloA });

  r.clock.now += MINUTE;
  const helloA2 = fakeBox();
  const again = await putSlot(r, a, slot, helloA2);
  assert.equal(again.status, 201);
  assert.equal(again.json.expiresAt, r.clock.now + 10 * MINUTE);
  assert.deepEqual((await getSlot(r, slot)).json, { hello: helloA2 });

  r.clock.now += 10 * MINUTE;
  assert.equal((await putSlot(r, b, slot)).status, 201);
});

test("a channel may hold 4 live slots; a 5th → 429 until one is deleted or expires", async (t) => {
  assert.equal(LIMITS.pairSlotsPerChannel, 4);
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 0 });
  const b = await setupChannel(r, { devices: 0 });
  const t0 = r.clock.now;
  const oldest = slotId();
  assert.equal((await putSlot(r, a, oldest)).status, 201);
  r.clock.now = t0 + MINUTE;
  const slots = [slotId(), slotId(), slotId()];
  for (const slot of slots) assert.equal((await putSlot(r, a, slot)).status, 201);
  expectError(await putSlot(r, a, slotId()), 429, "rate_limited");
  assert.equal((await putSlot(r, a, slots[0])).status, 201, "replacing one of its own is fine");
  assert.equal((await putSlot(r, b, slotId())).status, 201, "other channels have their own 4");

  assert.equal((await deleteSlot(r, slots[0], a.computer.token)).status, 204);
  assert.equal((await putSlot(r, a, slotId())).status, 201);
  expectError(await putSlot(r, a, slotId()), 429, "rate_limited");

  r.clock.now = t0 + 10 * MINUTE; // the oldest expires
  assert.equal((await putSlot(r, a, slotId())).status, 201);
});

test("slots expire 10 minutes after they're made", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  const t0 = r.clock.now;
  assert.equal((await putSlot(r, s, slot)).status, 201);
  assert.equal((await toComputer(r, slot)).status, 201);
  r.clock.now = t0 + 10 * MINUTE - 1;
  assert.equal((await getSlot(r, slot)).status, 200);
  r.clock.now = t0 + 10 * MINUTE;
  expectError(await getSlot(r, slot), 404, "not_found");
  expectError(await toComputer(r, slot), 404, "not_found");
  expectError(await readToComputer(r, slot, s.computer.token), 404, "not_found");
  expectError(await toPhone(r, slot, s.computer.token), 404, "not_found");
  expectError(await readToPhone(r, slot), 404, "not_found");
});

test("toComputer: anyone holding the slot may POST (201 {n}); only the owning computer may read; 4 at most, then 409", async (t) => {
  assert.equal(LIMITS.pairMessagesPerDirection, 4);
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, a, slot)).status, 201);
  for (const box of BAD_BOXES) {
    expectError(await postBox(r, slot, "toComputer", box), 400, "bad_request");
  }
  expectError(await postBox(r, slot, "toComputer", BIG_BOX), 413, "too_large");
  const boxes = [fakeBox(), fakeBox(), fakeBox(), fakeBox(4096)];
  for (const [i, box] of boxes.entries()) {
    const res = await toComputer(r, slot, box);
    assert.equal(res.status, 201);
    assert.deepEqual(res.json, { n: i + 1 });
  }
  expectError(await toComputer(r, slot), 409, "conflict");

  for (const token of [undefined, newToken().token, a.phones[0].token, b.computer.token]) {
    expectError(await readToComputer(r, slot, token), 401, "unauthorized");
  }
  const res = await readToComputer(r, slot, a.computer.token);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { messages: boxes.map((box, i) => ({ n: i + 1, box })) });
  assert.equal((await toPhone(r, slot, a.computer.token)).json.n, 1, "the other direction has its own 4");
});

test("toPhone: only the owning computer may POST; anyone holding the slot may read; 4 at most, then 409", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, a, slot)).status, 201);
  for (const token of [undefined, newToken().token, a.phones[0].token, b.computer.token]) {
    expectError(await toPhone(r, slot, token), 401, "unauthorized");
  }
  for (const box of BAD_BOXES) {
    expectError(await postBox(r, slot, "toPhone", box, a.computer.token), 400, "bad_request");
  }
  expectError(await postBox(r, slot, "toPhone", BIG_BOX, a.computer.token), 413, "too_large");
  const boxes = [fakeBox(), fakeBox(), fakeBox(), fakeBox()];
  for (const [i, box] of boxes.entries()) {
    const res = await toPhone(r, slot, a.computer.token, box);
    assert.equal(res.status, 201);
    assert.deepEqual(res.json, { n: i + 1 });
  }
  expectError(await toPhone(r, slot, a.computer.token), 409, "conflict");
  const res = await readToPhone(r, slot);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { messages: boxes.map((box, i) => ({ n: i + 1, box })) });
});

test("after= skips messages already seen and wait= waits for the next one, in both directions", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  const token = s.computer.token;
  assert.equal((await putSlot(r, s, slot)).status, 201);
  const [c1, c2, c3] = [fakeBox(), fakeBox(), fakeBox()];
  await toComputer(r, slot, c1);
  await toComputer(r, slot, c2);
  assert.deepEqual((await readToComputer(r, slot, token, "?after=0")).json.messages, [{ n: 1, box: c1 }, { n: 2, box: c2 }]);
  assert.deepEqual((await readToComputer(r, slot, token, "?after=1")).json.messages, [{ n: 2, box: c2 }]);
  assert.deepEqual((await readToComputer(r, slot, token, "?after=2")).json.messages, []);
  assert.deepEqual((await readToComputer(r, slot, token, "?after=99&wait=0")).json.messages, []);

  let started = Date.now();
  const forComputer = readToComputer(r, slot, token, "?after=2&wait=10");
  await until(() => waiting(r, slot, "toComputer") === 1, "the computer to wait");
  await toComputer(r, slot, c3);
  assert.deepEqual((await forComputer).json, { messages: [{ n: 3, box: c3 }] });
  assert.ok(Date.now() - started < 2000, "answered right away");

  const p1 = fakeBox();
  started = Date.now();
  const forPhone = readToPhone(r, slot, "?after=0&wait=10");
  await until(() => waiting(r, slot, "toPhone") === 1, "the phone to wait");
  await toPhone(r, slot, token, p1);
  assert.deepEqual((await forPhone).json, { messages: [{ n: 1, box: p1 }] });
  assert.ok(Date.now() - started < 2000, "answered right away");

  // A message already there answers at once; nothing new answers empty after `wait` seconds.
  started = Date.now();
  assert.deepEqual((await readToPhone(r, slot, "?after=0&wait=10")).json.messages, [{ n: 1, box: p1 }]);
  assert.ok(Date.now() - started < 2000);
  started = Date.now();
  assert.deepEqual((await readToPhone(r, slot, "?after=1&wait=1")).json, { messages: [] });
  const took = Date.now() - started;
  assert.ok(took >= 900 && took < 3000, `took ${took} ms`);

  for (const query of ["?after=-1", "?after=x", "?after=1.5", "?wait=1.5", "?wait=-2", "?wait=1000000000000000"]) {
    expectError(await readToPhone(r, slot, query), 400, "bad_request");
    expectError(await readToComputer(r, slot, token, query), 400, "bad_request");
  }
});

test("two requests may wait per slot and direction; a third → 429", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, s, slot)).status, 201);
  const phones = [readToPhone(r, slot, "?wait=10"), readToPhone(r, slot, "?wait=10")];
  await until(() => waiting(r, slot, "toPhone") === 2, "two phones to wait");
  expectError(await readToPhone(r, slot, "?wait=1"), 429, "rate_limited");
  assert.equal((await readToPhone(r, slot)).status, 200, "a read that doesn't wait is fine");
  const computer = readToComputer(r, slot, s.computer.token, "?wait=10");
  await until(() => waiting(r, slot, "toComputer") === 1, "the other direction to have its own places");

  const box = fakeBox();
  await toPhone(r, slot, s.computer.token, box);
  for (const res of await Promise.all(phones)) assert.deepEqual(res.json.messages, [{ n: 1, box }]);
  const back = fakeBox();
  await toComputer(r, slot, back);
  assert.deepEqual((await computer).json.messages, [{ n: 1, box: back }]);
});

test("DELETE /v1/pair/{slot} → 204, for the owning computer only; the computer's waiter gets 404, the phone's the messages so far", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, a, slot)).status, 201);
  for (const token of [undefined, newToken().token, a.phones[0].token, b.computer.token]) {
    expectError(await deleteSlot(r, slot, token), 401, "unauthorized");
  }
  assert.equal((await getSlot(r, slot)).status, 200);

  const phoneWaits = readToPhone(r, slot, "?wait=10");
  const computerWaits = readToComputer(r, slot, a.computer.token, "?wait=10");
  await until(() => waiting(r, slot, "toPhone") === 1 && waiting(r, slot, "toComputer") === 1, "both sides to wait");
  const del = await deleteSlot(r, slot, a.computer.token);
  assert.equal(del.status, 204);
  assert.equal(del.text, "");
  const phoneGot = await phoneWaits;
  assert.equal(phoneGot.status, 200, "a phone waiting for its last message isn't told the code vanished");
  assert.deepEqual(phoneGot.json, { messages: [] });
  expectError(await computerWaits, 404, "not_found");
  expectError(await getSlot(r, slot), 404, "not_found");
  expectError(await toComputer(r, slot), 404, "not_found");

  assert.equal((await deleteSlot(r, slot, a.computer.token)).status, 204, "a slot that isn't there is fine to delete");
  expectError(await deleteSlot(r, "bad", a.computer.token), 400, "bad_request");
});

test("the computer's last message stays readable for 2 minutes after it deletes the slot", async (t) => {
  // The computer sends "done" and deletes the slot straight away; a phone that was between two
  // waits must still get "done" rather than 404.
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, s, slot)).status, 201);
  const nonce = fakeBox();
  const done = fakeBox();
  await toPhone(r, slot, s.computer.token, nonce);
  await toPhone(r, slot, s.computer.token, done);
  assert.equal((await deleteSlot(r, slot, s.computer.token)).status, 204);
  const late = await readToPhone(r, slot, "?after=1&wait=10");
  assert.equal(late.status, 200);
  assert.deepEqual(late.json, { messages: [{ n: 2, box: done }] });
  expectError(await getSlot(r, slot), 404, "not_found");
  expectError(await toComputer(r, slot), 404, "not_found");
  expectError(await toPhone(r, slot, s.computer.token), 404, "not_found");
  r.clock.now += 2 * MINUTE;
  expectError(await readToPhone(r, slot), 404, "not_found");
});

test("a slot that expires while someone waits on it answers 404", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, s, slot)).status, 201);
  const phoneWaits = readToPhone(r, slot, "?wait=10");
  await until(() => waiting(r, slot, "toPhone") === 1, "the phone to wait");
  r.clock.now += 10 * MINUTE;
  r.relay.sweep();
  expectError(await phoneWaits, 404, "not_found");
});

test("unlinking a channel removes its pairing slots", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 0 });
  const slot = slotId();
  assert.equal((await putSlot(r, s, slot)).status, 201);
  const phoneWaits = readToPhone(r, slot, "?wait=10");
  await until(() => waiting(r, slot, "toPhone") === 1, "the phone to wait");
  assert.equal((await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token })).status, 204);
  expectError(await phoneWaits, 404, "not_found");
  expectError(await getSlot(r, slot), 404, "not_found");
  // The slot is free for another channel straight away.
  const other = await setupChannel(r, { devices: 0 });
  assert.equal((await putSlot(r, other, slot)).status, 201);
});
