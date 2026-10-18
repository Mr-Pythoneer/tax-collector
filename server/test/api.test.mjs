// The relay's HTTP API (docs/parent-link-v1.md §6.1): health, channels and unlinking, tokens,
// devices, the error format, and requests it must turn away. State, commands, pairing, rate
// limits, restarts and static files have their own files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LIMITS } from "../lib/relay.mjs";
import { openRelay, call, setupChannel, newToken, channelId, deviceId, fakeBox, fakeIp, expectError } from "./helpers.mjs";

const DAY = 86_400_000;
const B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/** The same bytes with a padding bit set: not canonical base64url, so not a valid ID or token. */
const nonCanonical = (text) => text.slice(0, -1) + B64URL[B64URL.indexOf(text.at(-1)) ^ 1];

const bearer = (token) => ({ authorization: "Bearer " + token });

/** Authorization headers that must never pass for `token`'s owner: missing, malformed, or a near miss. */
function badAuth(token) {
  const bytes = Buffer.from(token, "base64url");
  return [
    {},
    { authorization: "" },
    { authorization: "Bearer" },
    { authorization: token },
    { authorization: "Basic " + token },
    { authorization: "Token " + token },
    { authorization: "Bearer  " + token },
    bearer(token.slice(0, 42)),
    bearer(token + "A"),
    bearer(token + "="),
    bearer(nonCanonical(token)),
    bearer(bytes.toString("base64")),
    bearer(bytes.toString("hex")),
    bearer(Buffer.concat([bytes, Buffer.from([0])]).toString("base64url")),
  ];
}

const createChannel = (r, ch, token, body) =>
  call(r.base, "PUT", `/v1/channels/${ch}`, { token: token?.token, body: { setupCode: r.relay.setupCode, tokenHash: token?.hash, ...body } });

const presence = (r, s, awake = true) => call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { token: s.computer.token, body: { awake } });
const getState = (r, ch, phone) => call(r.base, "GET", `/v1/ch/${ch}/state`, { token: phone.token });
const putDevices = (r, s, devices) =>
  call(r.base, "PUT", `/v1/ch/${s.ch}/devices`, { token: s.computer.token, body: { devices: devices.map((d) => ({ id: d.id, tokenHash: d.hash })) } });
const newPhone = () => ({ id: deviceId(), ...newToken() });

/** A relay whose data folder already holds a known setup code. */
async function relayWithSetupCode(t, setupCode) {
  const dataDir = await mkdtemp(join(tmpdir(), "tc-relay-test-"));
  await writeFile(join(dataDir, "server.json"), JSON.stringify({ v: 1, instance: "knownsetupcodeinstance", setupCode, createdAt: 1 }));
  return openRelay(t, { dataDir });
}

// ---------------------------------------------------------------- health and setup code

test("GET /v1/health: ok, the version, the instance and the server's time", async (t) => {
  const r = await openRelay(t);
  const res = await call(r.base, "GET", "/v1/health");
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { ok: true, v: 1, instance: r.relay.instance, time: r.clock.now });
  assert.match(r.relay.instance, /^[A-Za-z0-9_-]{22}$/);
  assert.equal(res.headers.get("x-tc-instance"), r.relay.instance);
  assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
  r.clock.now += 1234;
  assert.equal((await call(r.base, "GET", "/v1/health")).json.time, r.clock.now);
});

test("a new data folder gets a 12-character Crockford setup code, saved in the folder", async (t) => {
  const r = await openRelay(t);
  assert.equal(r.relay.firstStart, true);
  assert.match(r.relay.setupCode, /^[0-9A-HJKMNP-TV-Z]{12}$/);
  const saved = JSON.parse(await readFile(join(r.dataDir, "server.json"), "utf8"));
  assert.equal(saved.setupCode, r.relay.setupCode);
  assert.equal(saved.instance, r.relay.instance);
});

// ---------------------------------------------------------------- PUT /v1/channels/{ch}

test("PUT /v1/channels/{ch}: 201 when created, 200 when it's already yours", async (t) => {
  const r = await openRelay(t);
  const ch = channelId();
  const computer = newToken();
  assert.equal((await createChannel(r, ch, computer)).status, 201);
  assert.equal((await createChannel(r, ch, computer)).status, 200);
  // The token now works on the channel's computer endpoints.
  assert.equal((await presence(r, { ch, computer })).status, 204);
});

test("PUT /v1/channels/{ch}: the setup code is normalised (any case, dashes, spaces, O/I/L), and a wrong one → 403", async (t) => {
  const r = await relayWithSetupCode(t, "01ABCDEFGHJK");
  assert.equal(r.relay.setupCode, "01ABCDEFGHJK");
  const ch = channelId();
  const computer = newToken();
  const put = (setupCode) => call(r.base, "PUT", `/v1/channels/${ch}`, { token: computer.token, body: { setupCode, tokenHash: computer.hash } });
  assert.equal((await put("01ab-cdef-ghjk")).status, 201);
  // Every spelling of the code makes a channel.
  for (const variant of ["01ABCDEFGHJK", "oL-AbCd-EfGh-Jk", " O i abcd efgh jk ", "0-1-A-B-C-D-E-F-G-H-J-K"]) {
    const other = channelId();
    const t2 = newToken();
    assert.equal((await call(r.base, "PUT", `/v1/channels/${other}`, { token: t2.token, body: { setupCode: variant, tokenHash: t2.hash } })).status, 201, variant);
  }
  // A wrong code makes nothing.
  for (const wrong of ["01ABCDEFGHJ", "01ABCDEFGHJKM", "01ABCDEFGHJX", "11ABCDEFGHJK", "", 12345, null, ["01ABCDEFGHJK"]]) {
    const t2 = newToken();
    expectError(await call(r.base, "PUT", `/v1/channels/${channelId()}`, { token: t2.token, body: { setupCode: wrong, tokenHash: t2.hash } }), 403, "forbidden");
  }
  // The channel's own computer is told "already yours" even with a wrong or missing code, so a
  // changed setup code doesn't cut off computers that are already linked.
  assert.equal((await put("01ABCDEFGHJX")).status, 200);
  assert.equal((await call(r.base, "PUT", `/v1/channels/${ch}`, { token: computer.token, body: { tokenHash: computer.hash } })).status, 200);
  // Someone else asking for that channel needs the code first: no hint whether it exists.
  const stranger = newToken();
  expectError(await call(r.base, "PUT", `/v1/channels/${ch}`, { token: stranger.token, body: { setupCode: "nope", tokenHash: stranger.hash } }), 403, "forbidden");
  expectError(await call(r.base, "PUT", `/v1/channels/${ch}`, { token: stranger.token, body: { setupCode: "01ABCDEFGHJK", tokenHash: stranger.hash } }), 409, "conflict");
});

test("PUT /v1/channels/{ch}: tokenHash must be SHA-256 of the bearer token's bytes (400), and a bearer is needed (401)", async (t) => {
  const r = await openRelay(t);
  const ch = channelId();
  const computer = newToken();
  const put = (tokenHash, token = computer.token) =>
    call(r.base, "PUT", `/v1/channels/${ch}`, { token, body: { setupCode: r.relay.setupCode, ...(tokenHash === undefined ? {} : { tokenHash }) } });
  expectError(await put(newToken().hash), 400, "bad_request");
  expectError(await put(undefined), 400, "bad_request");
  expectError(await put(createHash("sha256").update(computer.token).digest("base64url")), 400, "bad_request"); // hash of the text
  expectError(await put(Buffer.from(computer.hash, "base64url").toString("hex")), 400, "bad_request");
  expectError(await put(computer.hash, null), 401, "unauthorized");
  // None of that made the channel.
  assert.equal((await put(computer.hash)).status, 201);
});

test("PUT /v1/channels/{ch}: 409 when another token owns it, or when the token is already in use", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  expectError(await createChannel(r, a.ch, newToken()), 409, "conflict");
  assert.equal((await createChannel(r, a.ch, a.computer)).status, 200, "still a's");
  const second = channelId();
  expectError(await createChannel(r, second, a.computer), 409, "conflict");
  expectError(await createChannel(r, second, a.phones[0]), 409, "conflict");
});

test("PUT /v1/channels/{ch}: the 9th channel → 429; existing ones still answer 200; unlinking one makes room", async (t) => {
  assert.equal(LIMITS.channels, 8);
  const r = await openRelay(t);
  const made = [];
  for (let i = 0; i < 8; i++) made.push(await setupChannel(r, { devices: 0 }));
  const ninth = newToken();
  const ch9 = channelId();
  expectError(await createChannel(r, ch9, ninth), 429, "rate_limited");
  assert.equal((await createChannel(r, made[3].ch, made[3].computer)).status, 200);
  assert.equal((await call(r.base, "DELETE", `/v1/channels/${made[0].ch}`, { token: made[0].computer.token })).status, 204);
  assert.equal((await createChannel(r, ch9, ninth)).status, 201);
});

test("malformed channel IDs → 400", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const good = channelId();
  const bad = ["abc", good + "A", good.slice(0, 21), good.slice(0, 21) + "=", good.slice(0, 10) + "+" + good.slice(11), nonCanonical(good), "a".repeat(22)];
  for (const ch of bad) {
    expectError(await call(r.base, "PUT", `/v1/channels/${ch}`, { token: newToken().token, body: {}, ip: fakeIp() }), 400, "bad_request");
    expectError(await call(r.base, "DELETE", `/v1/channels/${ch}`, { token: s.computer.token }), 400, "bad_request");
    expectError(await call(r.base, "POST", `/v1/ch/${ch}/presence`, { token: s.computer.token, body: { awake: true } }), 400, "bad_request");
    expectError(await getState(r, ch, s.phones[0]), 400, "bad_request");
  }
});

// ---------------------------------------------------------------- DELETE /v1/channels/{ch}

test("DELETE /v1/channels/{ch} → 204; then calls on it get 410 {unlinkedAt}, until the marker expires after 30 days", async (t) => {
  assert.equal(LIMITS.unlinkedMarkerMs, 30 * DAY);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [phone] = s.phones;
  r.clock.now += 5000;
  const unlinkedAt = r.clock.now;
  const del = await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token });
  assert.equal(del.status, 204);
  assert.equal(del.text, "");

  r.clock.now += 1000;
  const gone = await getState(r, s.ch, phone);
  expectError(gone, 410, "gone", ["unlinkedAt"]);
  assert.equal(gone.json.unlinkedAt, unlinkedAt);
  const cmd = await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: phone.token, body: { box: fakeBox() } });
  expectError(cmd, 410, "gone", ["unlinkedAt"]);
  assert.equal(cmd.json.unlinkedAt, unlinkedAt);
  expectError(await presence(r, s), 410, "gone", ["unlinkedAt"]);

  // Still there a millisecond short of 30 days, even after a sweep.
  r.clock.now = unlinkedAt + 30 * DAY - 1;
  r.relay.sweep();
  expectError(await getState(r, s.ch, phone), 410, "gone", ["unlinkedAt"]);

  // At 30 days the sweep drops it. The phone's registration went with the channel.
  r.clock.now = unlinkedAt + 30 * DAY;
  r.relay.sweep();
  expectError(await getState(r, s.ch, phone), 401, "unauthorized");
  expectError(await presence(r, s), 404, "not_found");
});

test("DELETE /v1/channels/{ch} needs the computer token: 401 for any other, 404 for an unknown channel", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const other = await setupChannel(r, { devices: 1 });
  for (const token of [undefined, newToken().token, s.phones[0].token, other.computer.token, other.phones[0].token]) {
    expectError(await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token }), 401, "unauthorized");
  }
  expectError(await call(r.base, "DELETE", `/v1/channels/${channelId()}`, { token: s.computer.token }), 404, "not_found");
  assert.equal((await getState(r, s.ch, s.phones[0])).status, 204, "the channel is untouched");
});

test("re-creating an unlinked channel clears its marker", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [phone] = s.phones;
  assert.equal((await call(r.base, "DELETE", `/v1/channels/${s.ch}`, { token: s.computer.token })).status, 204);
  expectError(await getState(r, s.ch, phone), 410, "gone", ["unlinkedAt"]);
  assert.equal((await createChannel(r, s.ch, s.computer)).status, 201);
  // Not gone any more; the phone has to be registered again.
  expectError(await getState(r, s.ch, phone), 401, "unauthorized");
  assert.equal((await putDevices(r, s, [phone])).status, 204);
  assert.equal((await getState(r, s.ch, phone)).status, 204);
});

// ---------------------------------------------------------------- tokens

test("computer endpoints: missing, malformed and wrong tokens → 401, including phone tokens and other computers' tokens", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 1 });
  const endpoints = [
    ["PUT", `/v1/ch/${a.ch}/devices`, { devices: [] }],
    ["PUT", `/v1/ch/${a.ch}/state`, { seq: 1, copies: {} }],
    ["GET", `/v1/ch/${a.ch}/cmd`],
    ["POST", `/v1/ch/${a.ch}/cmd/ack`, { upTo: 0 }],
    ["POST", `/v1/ch/${a.ch}/presence`, { awake: false }],
    ["DELETE", `/v1/channels/${a.ch}`],
  ];
  const wrong = [...badAuth(a.computer.token), bearer(a.phones[0].token), bearer(b.computer.token), bearer(b.phones[0].token), bearer(newToken().token)];
  for (const [method, path, body] of endpoints) {
    for (const headers of wrong) {
      expectError(await call(r.base, method, path, { headers, body, ip: fakeIp() }), 401, "unauthorized");
    }
  }
  // Nothing got through: the phone is still registered, and the computer is still awake.
  const st = await getState(r, a.ch, a.phones[0]);
  assert.equal(st.status, 204);
  assert.equal(st.headers.get("x-tc-computer-awake"), "true");
});

test("phone endpoints: missing, malformed and wrong tokens → 401, the computer's own token → 401, another channel's phone → 403", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 1 });
  const endpoints = [
    ["GET", `/v1/ch/${a.ch}/state`],
    ["POST", `/v1/ch/${a.ch}/cmd`, { box: fakeBox() }],
  ];
  const wrong = [...badAuth(a.phones[0].token), bearer(a.computer.token), bearer(b.computer.token), bearer(newToken().token)];
  for (const [method, path, body] of endpoints) {
    for (const headers of wrong) {
      expectError(await call(r.base, method, path, { headers, body, ip: fakeIp() }), 401, "unauthorized");
    }
    expectError(await call(r.base, method, path, { token: b.phones[0].token, body }), 403, "forbidden");
  }
  const queued = await call(r.base, "GET", `/v1/ch/${a.ch}/cmd`, { token: a.computer.token });
  assert.deepEqual(queued.json.commands, [], "no command was queued");
});

test("the relay keeps token hashes, never tokens, and names its files by hashes rather than channel IDs", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 2 });
  const [p1, p2] = s.phones;
  await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq: 1, copies: { [p1.id]: fakeBox(), [p2.id]: fakeBox() } } });
  await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p1.token, body: { box: fakeBox() } });
  await call(r.base, "PUT", `/v1/pair/${channelId()}`, { token: s.computer.token, body: { ch: s.ch, hello: fakeBox() } });
  await r.relay.store.flush();
  const names = (await readdir(r.dataDir, { recursive: true })).map(String);
  const files = [];
  for (const name of names) {
    try {
      files.push(await readFile(join(r.dataDir, name), "utf8"));
    } catch (e) {
      if (e.code !== "EISDIR") throw e;
    }
  }
  const everything = files.join("\n");
  assert.ok(files.length >= 5, "server, channel, state, commands and pairing files: " + names.join(", "));
  for (const token of [s.computer.token, p1.token, p2.token]) assert.ok(!everything.includes(token), "a token is on disk");
  for (const hash of [s.computer.hash, p1.hash, p2.hash]) assert.ok(everything.includes(hash), "a token hash is missing from disk");
  for (const name of names) assert.ok(!name.includes(s.ch), "a file is named after the channel: " + name);
});

// ---------------------------------------------------------------- PUT /v1/ch/{ch}/devices

test("PUT devices replaces the list: removed phones get 401 and lose their state copy for good", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 2 });
  const [a, b] = s.phones;
  const c = newPhone();
  const boxB = fakeBox();
  const put = await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq: 1, copies: { [a.id]: fakeBox(), [b.id]: boxB } } });
  assert.equal(put.status, 204);

  const replace = await putDevices(r, s, [b, c]);
  assert.equal(replace.status, 204);
  assert.equal(replace.text, "");
  expectError(await getState(r, s.ch, a), 401, "unauthorized");
  assert.equal((await getState(r, s.ch, b)).json.box, boxB, "b keeps its copy");
  assert.equal((await getState(r, s.ch, c)).status, 204, "c is registered, with no copy yet");

  // a's copy was dropped, not hidden: registering a again doesn't bring it back.
  assert.equal((await putDevices(r, s, [a, b, c])).status, 204);
  assert.equal((await getState(r, s.ch, a)).status, 204);
  assert.equal((await getState(r, s.ch, b)).json.box, boxB);

  // An empty list removes every phone.
  assert.equal((await putDevices(r, s, [])).status, 204);
  for (const phone of [a, b, c]) expectError(await getState(r, s.ch, phone), 401, "unauthorized");
});

test("PUT devices: at most 8; a 9th → 400 and the list is unchanged", async (t) => {
  assert.equal(LIMITS.devicesPerChannel, 8);
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 8 });
  for (const phone of s.phones) assert.equal((await getState(r, s.ch, phone)).status, 204);
  const ninth = newPhone();
  expectError(await putDevices(r, s, [...s.phones, ninth]), 400, "bad_request");
  expectError(await getState(r, s.ch, ninth), 401, "unauthorized");
  assert.equal((await getState(r, s.ch, s.phones[7])).status, 204);
});

test("PUT devices: a device listed twice, by ID or by token, → 400", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [a] = s.phones;
  const b = newPhone();
  expectError(await putDevices(r, s, [a, { ...b, id: a.id }]), 400, "bad_request");
  expectError(await putDevices(r, s, [a, { ...b, hash: a.hash }]), 400, "bad_request");
  expectError(await getState(r, s.ch, b), 401, "unauthorized");
  assert.equal((await getState(r, s.ch, a)).status, 204);
});

test("PUT devices: malformed lists and entries → 400", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const ok = { id: deviceId(), tokenHash: newToken().hash };
  const bodies = [
    {},
    { devices: {} },
    { devices: "x" },
    { devices: null },
    { devices: [null] },
    { devices: ["x"] },
    { devices: [{ ...ok, id: ok.id.toUpperCase() }] },
    { devices: [{ ...ok, id: "phone-1" }] },
    { devices: [{ ...ok, id: ok.id.replaceAll("-", "") }] },
    { devices: [{ tokenHash: ok.tokenHash }] },
    { devices: [{ id: ok.id }] },
    { devices: [{ ...ok, tokenHash: Buffer.from(ok.tokenHash, "base64url").toString("hex") }] },
    { devices: [{ ...ok, tokenHash: ok.tokenHash.slice(0, 42) }] },
    { devices: [{ ...ok, tokenHash: nonCanonical(ok.tokenHash) }] },
  ];
  for (const body of bodies) {
    expectError(await call(r.base, "PUT", `/v1/ch/${s.ch}/devices`, { token: s.computer.token, body }), 400, "bad_request");
  }
  assert.equal((await getState(r, s.ch, s.phones[0])).status, 204, "the list is unchanged");
});

test("PUT devices: a token another channel uses, or any computer's token, → 409", async (t) => {
  const r = await openRelay(t);
  const a = await setupChannel(r, { devices: 1 });
  const b = await setupChannel(r, { devices: 0 });
  const [phone] = a.phones;
  const claim = (s, hash) => call(r.base, "PUT", `/v1/ch/${s.ch}/devices`, { token: s.computer.token, body: { devices: [{ id: deviceId(), tokenHash: hash }] } });
  expectError(await claim(b, phone.hash), 409, "conflict");
  expectError(await claim(b, b.computer.hash), 409, "conflict");
  expectError(await claim(b, a.computer.hash), 409, "conflict");
  assert.equal((await getState(r, a.ch, phone)).status, 204, "the phone still belongs to a");
  // Re-registering a's own list is fine; once a lets the phone go, b can have its token.
  assert.equal((await putDevices(r, a, [phone])).status, 204);
  assert.equal((await putDevices(r, a, [])).status, 204);
  assert.equal((await claim(b, phone.hash)).status, 204);
  assert.equal((await getState(r, b.ch, phone)).status, 204);
  expectError(await getState(r, a.ch, phone), 403, "forbidden");
});

// ---------------------------------------------------------------- bad requests

test("request bodies that aren't JSON objects → 400 bad_request", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const slot = channelId();
  assert.equal((await call(r.base, "PUT", `/v1/pair/${slot}`, { token: s.computer.token, body: { ch: s.ch, hello: fakeBox() } })).status, 201);
  const newCh = channelId();
  const fresh = newToken();
  const endpoints = [
    ["PUT", `/v1/channels/${newCh}`, fresh.token],
    ["PUT", `/v1/ch/${s.ch}/devices`, s.computer.token],
    ["PUT", `/v1/ch/${s.ch}/state`, s.computer.token],
    ["POST", `/v1/ch/${s.ch}/cmd`, s.phones[0].token],
    ["POST", `/v1/ch/${s.ch}/cmd/ack`, s.computer.token],
    ["POST", `/v1/ch/${s.ch}/presence`, s.computer.token],
    ["PUT", `/v1/pair/${slot}`, s.computer.token],
    ["POST", `/v1/pair/${slot}/toComputer`, undefined],
    ["POST", `/v1/pair/${slot}/toPhone`, s.computer.token],
  ];
  const bodies = ["", " ", "not json", "{", '{"a":1', "[]", "[{}]", "null", "42", '"text"', "true"];
  for (const [method, path, token] of endpoints) {
    for (const body of bodies) {
      expectError(await call(r.base, method, path, { token, body, ip: fakeIp() }), 400, "bad_request");
    }
  }
  // None of it did anything.
  expectError(await presence(r, { ch: newCh, computer: fresh }), 404, "not_found");
  assert.equal((await getState(r, s.ch, s.phones[0])).status, 204);
  assert.deepEqual((await call(r.base, "GET", `/v1/ch/${s.ch}/cmd`, { token: s.computer.token })).json.commands, []);
  assert.deepEqual((await call(r.base, "GET", `/v1/pair/${slot}/toComputer`, { token: s.computer.token })).json.messages, []);
  assert.deepEqual((await call(r.base, "GET", `/v1/pair/${slot}/toPhone`)).json.messages, []);
});

test("unknown endpoints → 404 not_found, even with a valid token", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const slot = channelId();
  const cases = [
    ["GET", "/v1/"],
    ["GET", "/v1/nope"],
    ["GET", "/v1/health/extra"],
    ["POST", "/v1/health"],
    ["DELETE", "/v1/health"],
    ["GET", "/v1/channels"],
    ["GET", `/v1/channels/${s.ch}`],
    ["POST", `/v1/channels/${s.ch}`],
    ["PUT", `/v1/channels/${s.ch}/extra`],
    ["GET", `/v1/ch/${s.ch}`],
    ["GET", `/v1/ch/${s.ch}/nope`],
    ["GET", `/v1/ch/${s.ch}/devices`],
    ["DELETE", `/v1/ch/${s.ch}/state`],
    ["POST", `/v1/ch/${s.ch}/state/`],
    ["PUT", `/v1/ch/${s.ch}/cmd`],
    ["GET", `/v1/ch/${s.ch}/cmd/ack`],
    ["GET", `/v1/ch/${s.ch}/presence`],
    ["GET", "/v1/pair"],
    ["POST", `/v1/pair/${slot}`],
    ["GET", `/v1/pair/${slot}/nope`],
    ["PUT", `/v1/pair/${slot}/toPhone`],
    ["GET", `/v1/pair/${slot}/toPhone/extra`],
  ];
  for (const [method, path] of cases) {
    expectError(await call(r.base, method, path, { token: s.computer.token }), 404, "not_found");
  }
  // Outside /v1/ the static side answers, and it has nothing at these paths either.
  for (const path of ["/v2/health", "/V1/health", "/v1", "/api/v1/health"]) {
    assert.equal((await call(r.base, "GET", path)).status, 404, path);
  }
});
