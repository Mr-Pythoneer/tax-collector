// Commands from phones to the computer (docs/parent-link-v1.md §5.1, §6.1): queueing, the
// computer's long-poll, acks, and the limits on all three.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS } from "../lib/relay.mjs";
import { openRelay, call, setupChannel, fakeBox, expectError, until } from "./helpers.mjs";

const DAY = 86_400_000;

const post = (r, s, phone, box = fakeBox()) => call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: phone.token, body: { box } });
const poll = (r, s, query = "") => call(r.base, "GET", `/v1/ch/${s.ch}/cmd${query}`, { token: s.computer.token });
const ack = (r, s, upTo) => call(r.base, "POST", `/v1/ch/${s.ch}/cmd/ack`, { token: s.computer.token, body: { upTo } });
const seqs = async (r, s) => (await poll(r, s)).json.commands.map((c) => c.seq);
const waiting = (r, s) => r.relay.waiters.count("cmd:" + s.ch);

test("POST cmd → 201 {seq, receivedAt}; the computer gets every command after ackedUpTo, with its device", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 2 });
  const [a, b] = s.phones;
  const sent = [];
  for (const [i, phone] of [a, b, a].entries()) {
    r.clock.now += 1000;
    const box = fakeBox(100 + i);
    const res = await post(r, s, phone, box);
    assert.equal(res.status, 201);
    assert.deepEqual(res.json, { seq: i + 1, receivedAt: r.clock.now });
    sent.push({ seq: i + 1, dev: phone.id, box, receivedAt: r.clock.now });
  }
  r.clock.now += 1000;
  const res = await poll(r, s);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { serverTime: r.clock.now, commands: sent });
  assert.deepEqual((await poll(r, s, "?wait=0")).json.commands, sent, "reading doesn't remove anything; only ack does");

  const other = await setupChannel(r, { devices: 1 });
  assert.equal((await post(r, other, other.phones[0])).json.seq, 1, "each channel counts its own seqs");
});

test("a command box is at most 16 KB: 16384 bytes → 201, one more → 413", async (t) => {
  assert.equal(LIMITS.commandBoxBytes, 16 * 1024);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  assert.equal((await post(r, s, p, fakeBox(16 * 1024))).status, 201);
  expectError(await post(r, s, p, fakeBox(16 * 1024 + 1)), 413, "too_large");
  expectError(await post(r, s, p, fakeBox(20 * 1024)), 413, "too_large");
  // Something that isn't a box at all is a bad request.
  for (const box of [undefined, "", "not base64!", fakeBox(27), 42, null]) {
    expectError(await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box } }), 400, "bad_request");
  }
  assert.deepEqual(await seqs(r, s), [1]);
});

test("ack drops commands up to upTo, clamps upTo to the last seq, and never moves backwards", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq: 1, copies: { [p.id]: fakeBox() } } });
  const phoneSees = async () => {
    const { ackedUpTo, lastCmdSeq } = (await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: p.token })).json;
    return { ackedUpTo, lastCmdSeq };
  };
  for (let i = 0; i < 3; i++) await post(r, s, p);

  const res = await ack(r, s, 2);
  assert.equal(res.status, 204);
  assert.equal(res.text, "");
  assert.deepEqual(await seqs(r, s), [3]);
  assert.deepEqual(await phoneSees(), { ackedUpTo: 2, lastCmdSeq: 3 });

  assert.equal((await ack(r, s, 1)).status, 204, "an older ack is accepted…");
  assert.equal((await ack(r, s, 0)).status, 204);
  assert.deepEqual(await phoneSees(), { ackedUpTo: 2, lastCmdSeq: 3 }, "…and changes nothing");
  assert.deepEqual(await seqs(r, s), [3]);

  assert.equal((await ack(r, s, 1_000_000)).status, 204);
  assert.deepEqual(await phoneSees(), { ackedUpTo: 3, lastCmdSeq: 3 }, "clamped to the last seq");
  assert.deepEqual(await seqs(r, s), []);
  // So a command sent afterwards isn't swallowed by that ack.
  assert.equal((await post(r, s, p)).json.seq, 4);
  assert.deepEqual(await seqs(r, s), [4]);

  for (const upTo of [undefined, -1, 1.5, "4", null, true, 2 ** 53]) {
    expectError(await ack(r, s, upTo), 400, "bad_request");
  }
  assert.deepEqual(await seqs(r, s), [4]);
});

test("at most 500 commands wait per channel: more → 429 until the computer acks", async (t) => {
  assert.equal(LIMITS.commandsPerChannel, 500);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const box = fakeBox(32);
  for (let batch = 0; batch < 4; batch++) {
    const res = await Promise.all(Array.from({ length: 100 }, () => post(r, s, p, box)));
    assert.deepEqual([...new Set(res.map((x) => x.status))], [201]);
  }
  // The last 100 places, asked for 110 times at once: exactly 100 get in.
  const last = await Promise.all(Array.from({ length: 110 }, () => post(r, s, p, box)));
  assert.equal(last.filter((x) => x.status === 201).length, 100);
  const refused = last.filter((x) => x.status !== 201);
  assert.equal(refused.length, 10);
  for (const res of refused) expectError(res, 429, "rate_limited");
  assert.deepEqual(await seqs(r, s), Array.from({ length: 500 }, (_, i) => i + 1));

  assert.equal((await ack(r, s, 1)).status, 204);
  assert.equal((await post(r, s, p, box)).json.seq, 501, "refused commands didn't use up seqs");
  expectError(await post(r, s, p, box), 429, "rate_limited");
});

test("commands older than 14 days are dropped, which also makes room for new ones", async (t) => {
  assert.equal(LIMITS.commandMaxAgeMs, 14 * DAY);
  const r = await openRelay(t, { limits: { commandsPerChannel: 3 } });
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const t0 = r.clock.now;
  await post(r, s, p);
  await post(r, s, p);
  r.clock.now = t0 + DAY;
  await post(r, s, p);
  expectError(await post(r, s, p), 429, "rate_limited");

  r.clock.now = t0 + 14 * DAY - 1;
  assert.deepEqual(await seqs(r, s), [1, 2, 3]);
  expectError(await post(r, s, p), 429, "rate_limited");
  r.clock.now = t0 + 14 * DAY;
  assert.deepEqual(await seqs(r, s), [3]);
  assert.equal((await post(r, s, p)).json.seq, 4, "room again, and seqs keep counting");

  // The periodic sweep drops them too, for a computer that never asks.
  r.clock.now = t0 + 15 * DAY;
  r.relay.sweep();
  assert.deepEqual(r.relay.channels.get(s.ch).commands.map((c) => c.seq), [4]);
});

test("a long-poll answers as soon as a command arrives", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const started = Date.now();
  const waiter = poll(r, s, "?wait=10");
  await until(() => waiting(r, s) === 1, "the long-poll to wait");
  const box = fakeBox();
  const sent = await post(r, s, p, box);
  const res = await waiter;
  assert.ok(Date.now() - started < 2000, "answered right away");
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { serverTime: r.clock.now, commands: [{ seq: sent.json.seq, dev: p.id, box, receivedAt: sent.json.receivedAt }] });
  assert.equal(waiting(r, s), 0);
});

test("a long-poll with nothing to return answers an empty list after `wait` seconds; without wait it answers at once", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  let started = Date.now();
  const res = await poll(r, s, "?wait=1");
  const took = Date.now() - started;
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { serverTime: r.clock.now, commands: [] });
  assert.ok(took >= 900 && took < 3000, `took ${took} ms`);
  for (const query of ["", "?wait=0", "?wait="]) {
    started = Date.now();
    assert.deepEqual((await poll(r, s, query)).json.commands, []);
    assert.ok(Date.now() - started < 900, query || "no wait");
  }
});

test("wait is clamped to 25 seconds, and must be a whole number → 400 otherwise", async (t) => {
  assert.equal(LIMITS.maxWaitSeconds, 25);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  for (const wait of ["-1", "1.5", "abc", "1e3", "0x10", " 1", "+1", "1000000000000000"]) {
    expectError(await poll(r, s, "?wait=" + encodeURIComponent(wait)), 400, "bad_request");
  }

  // With a command already there, any wait answers at once.
  await post(r, s, p);
  assert.deepEqual((await poll(r, s, "?wait=999999999999999")).json.commands.map((c) => c.seq), [1]);
  await ack(r, s, 1);

  // With nothing there, an hour's wait is accepted and becomes a 25-second timer.
  const delays = [];
  const realSetTimeout = globalThis.setTimeout;
  globalThis.setTimeout = function (fn, ms, ...args) {
    delays.push(ms);
    return realSetTimeout.call(this, fn, ms, ...args);
  };
  let waiter;
  try {
    waiter = poll(r, s, "?wait=3600");
    await until(() => waiting(r, s) === 1, "the long-poll to wait");
  } finally {
    globalThis.setTimeout = realSetTimeout;
  }
  assert.ok(delays.includes(25_000), "a 25 s timer: " + delays.join(", "));
  assert.ok(!delays.includes(3_600_000), "no hour-long timer");
  const sent = await post(r, s, p);
  const res = await waiter;
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.commands.map((c) => c.seq), [sent.json.seq]);
});

test("two long-polls may wait per channel: a third → 429; one that doesn't wait is fine; a client that leaves frees its place", async (t) => {
  assert.equal(LIMITS.waitingPerChannel, 2);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const other = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  const first = poll(r, s, "?wait=10");
  const leaving = new AbortController();
  const second = fetch(`${r.base}/v1/ch/${s.ch}/cmd?wait=10`, { headers: { authorization: "Bearer " + s.computer.token }, signal: leaving.signal }).catch((e) => e);
  await until(() => waiting(r, s) === 2, "two long-polls to wait");

  expectError(await poll(r, s, "?wait=1"), 429, "rate_limited");
  assert.equal((await poll(r, s, "?wait=0")).status, 200);
  const otherWaits = poll(r, other, "?wait=10");
  await until(() => waiting(r, other) === 1, "another channel's long-poll to wait");

  leaving.abort();
  assert.equal((await second).name, "AbortError");
  await until(() => waiting(r, s) === 1, "the abandoned long-poll to be let go");
  const third = poll(r, s, "?wait=10");
  await until(() => waiting(r, s) === 2, "a new long-poll to take its place");

  const sent = await post(r, s, p);
  for (const res of await Promise.all([first, third])) {
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.commands.map((c) => c.seq), [sent.json.seq], "one command answers everyone waiting");
  }
  assert.equal(waiting(r, s), 0);
  assert.equal(waiting(r, other), 1, "the other channel's poll is still waiting");
  await post(r, other, other.phones[0]);
  assert.equal((await otherWaits).json.commands.length, 1);
});

test("unlinking the channel answers its waiting long-poll with 410", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const waiter = poll(r, s, "?wait=10");
  await until(() => waiting(r, s) === 1, "the long-poll to wait");
  r.clock.now += 1000;
  assert.equal((await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token })).status, 204);
  const res = await waiter;
  expectError(res, 410, "gone", ["unlinkedAt"]);
  assert.equal(res.json.unlinkedAt, r.clock.now);
});
