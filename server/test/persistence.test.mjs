// What survives a restart (docs/parent-link-v1.md §6.1 "Server reset", §6.2): the data folder
// holds everything, and a relay started on the same folder carries on where the last one stopped.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Relay } from "../lib/relay.mjs";
import { startRelay, call, setupChannel, channelId, newToken, fakeBox, expectError, quiet } from "./helpers.mjs";

const MINUTE = 60_000;
const DAY = 86_400_000;

/** Like startRelay, with a setup code pinned the way TC_SETUP_CODE pins it. */
async function startPinned({ dataDir, setupCode, start = 1_800_000_000_000 }) {
  const clock = { now: start };
  const relay = await Relay.open({ dataDir, setupCode, now: () => clock.now, log: quiet });
  const server = relay.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    relay,
    server,
    clock,
    dataDir: relay.dataDir,
    base: `http://127.0.0.1:${server.address().port}`,
    async stop() {
      await relay.close();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

/**
 * Starts relays one after another on one data folder (stopping the one before); stops the last
 * and deletes the folder when the test ends. `wipe()` stops the current relay and deletes the folder.
 */
function relays(t) {
  let current = null;
  let dataDir = null;
  t.after(async () => {
    await current?.stop();
    if (dataDir) await rm(dataDir, { recursive: true, force: true });
  });
  const restart = async (options = {}) => {
    await current?.stop();
    dataDir ??= await mkdtemp(join(tmpdir(), "tc-relay-test-"));
    current = options.setupCode ? await startPinned({ ...options, dataDir }) : await startRelay({ ...options, dataDir });
    return current;
  };
  restart.stop = async () => {
    await current?.stop();
    current = null;
  };
  restart.wipe = async () => {
    await restart.stop();
    await rm(dataDir, { recursive: true, force: true });
  };
  return restart;
}

const getState = (r, s, phone) => call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: phone.token });

test("a restart keeps the instance, setup code, channels, devices, state, commands, acks, unlinked markers and live slots", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const { instance, setupCode } = r1.relay;
  const a = await setupChannel(r1, { devices: 3 });
  const [p1, p2, removed] = a.phones;
  const C = { token: a.computer.token };
  assert.equal((await call(r1.base, "PUT", `/v1/ch/${a.ch}/devices`, { ...C, body: { devices: [p1, p2].map((p) => ({ id: p.id, tokenHash: p.hash })) } })).status, 204);

  const box1 = fakeBox(100);
  const box2 = fakeBox(120);
  assert.equal((await call(r1.base, "PUT", `/v1/ch/${a.ch}/state`, { ...C, body: { seq: 7, copies: { [p1.id]: box1, [p2.id]: box2 } } })).status, 204);
  const updatedAt = r1.clock.now;

  const commands = [];
  for (let i = 0; i < 3; i++) {
    r1.clock.now += 1000;
    const box = fakeBox(50 + i);
    const res = await call(r1.base, "POST", `/v1/ch/${a.ch}/cmd`, { token: p1.token, body: { box } });
    commands.push({ seq: res.json.seq, dev: p1.id, box, receivedAt: res.json.receivedAt });
  }
  assert.equal((await call(r1.base, "POST", `/v1/ch/${a.ch}/cmd/ack`, { ...C, body: { upTo: 1 } })).status, 204);

  const slot = channelId();
  const hello = fakeBox();
  const [toComputerBox, toPhoneBox] = [fakeBox(), fakeBox()];
  assert.equal((await call(r1.base, "PUT", `/v1/pair/${slot}`, { ...C, body: { ch: a.ch, hello } })).status, 201);
  assert.equal((await call(r1.base, "POST", `/v1/pair/${slot}/toComputer`, { body: { box: toComputerBox } })).status, 201);
  assert.equal((await call(r1.base, "POST", `/v1/pair/${slot}/toPhone`, { ...C, body: { box: toPhoneBox } })).status, 201);

  const b = await setupChannel(r1, { devices: 1 });
  r1.clock.now += 1000;
  const unlinkedAt = r1.clock.now;
  assert.equal((await call(r1.base, "DELETE", `/v1/channels/${b.ch}`, { token: b.computer.token })).status, 204);

  // Another computer is awake at the restart; its last request was a long-poll.
  const w = await setupChannel(r1, { devices: 1 });
  assert.equal((await call(r1.base, "PUT", `/v1/ch/${w.ch}/state`, { token: w.computer.token, body: { seq: 1, copies: { [w.phones[0].id]: fakeBox() } } })).status, 204);
  r1.clock.now += 1000;
  const wSeen = r1.clock.now;
  assert.equal((await call(r1.base, "GET", `/v1/ch/${w.ch}/cmd`, { token: w.computer.token })).status, 200);

  // a's last word before the restart: it's going to sleep.
  r1.clock.now += 1000;
  const lastSeen = r1.clock.now;
  assert.equal((await call(r1.base, "POST", `/v1/ch/${a.ch}/presence`, { ...C, body: { awake: false } })).status, 204);

  const r2 = await restart({ start: r1.clock.now + MINUTE });
  assert.equal(r2.relay.firstStart, false);
  assert.equal(r2.relay.instance, instance);
  assert.equal(r2.relay.setupCode, setupCode);
  const health = await call(r2.base, "GET", "/v1/health");
  assert.equal(health.json.instance, instance);
  assert.equal(health.headers.get("x-tc-instance"), instance);

  // Devices and state copies, liveness, ackedUpTo and lastCmdSeq.
  const st1 = await getState(r2, a, p1);
  assert.equal(st1.status, 200);
  assert.deepEqual(st1.json, {
    seq: 7,
    box: box1,
    updatedAt,
    serverTime: r2.clock.now,
    computerSeen: lastSeen,
    computerAwake: false,
    ackedUpTo: 1,
    lastCmdSeq: 3,
  });
  assert.equal((await getState(r2, a, p2)).json.box, box2);
  expectError(await getState(r2, a, removed), 401, "unauthorized");
  const stW = await getState(r2, w, w.phones[0]);
  assert.equal(stW.json.computerAwake, true, "awake is kept as well as asleep");
  assert.equal(stW.json.computerSeen, wSeen, "a GET cmd's time is kept even though it saves nothing itself");

  // Queued commands, then the seq carries on.
  const queued = await call(r2.base, "GET", `/v1/ch/${a.ch}/cmd`, C);
  assert.deepEqual(queued.json.commands, commands.slice(1));
  assert.equal((await call(r2.base, "POST", `/v1/ch/${a.ch}/cmd`, { token: p2.token, body: { box: fakeBox() } })).json.seq, 4);
  assert.equal((await getState(r2, a, p1)).json.computerAwake, true, "its first request after the restart woke it");

  // The channel is still the computer's, with the same setup code.
  const again = await call(r2.base, "PUT", `/v1/channels/${a.ch}`, { ...C, body: { setupCode, tokenHash: a.computer.hash } });
  assert.equal(again.status, 200);

  // The unlinked marker.
  const gone = await getState(r2, b, b.phones[0]);
  expectError(gone, 410, "gone", ["unlinkedAt"]);
  assert.equal(gone.json.unlinkedAt, unlinkedAt);

  // The live pairing slot, with its messages; their count carries on.
  assert.deepEqual((await call(r2.base, "GET", `/v1/pair/${slot}`)).json, { hello });
  assert.deepEqual((await call(r2.base, "GET", `/v1/pair/${slot}/toComputer`, C)).json, { messages: [{ n: 1, box: toComputerBox }] });
  assert.deepEqual((await call(r2.base, "GET", `/v1/pair/${slot}/toPhone`)).json, { messages: [{ n: 1, box: toPhoneBox }] });
  assert.equal((await call(r2.base, "POST", `/v1/pair/${slot}/toComputer`, { body: { box: fakeBox() } })).json.n, 2);
});

test("after a restart, expired slots, commands older than 14 days and unlinked markers older than 30 days are gone", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const t0 = r1.clock.now;
  const a = await setupChannel(r1, { devices: 1 });
  const [p] = a.phones;
  const C = { token: a.computer.token };
  assert.equal((await call(r1.base, "PUT", `/v1/ch/${a.ch}/state`, { ...C, body: { seq: 1, copies: { [p.id]: fakeBox() } } })).status, 204);
  assert.equal((await call(r1.base, "POST", `/v1/ch/${a.ch}/cmd`, { token: p.token, body: { box: fakeBox() } })).status, 201);
  const slot = channelId();
  assert.equal((await call(r1.base, "PUT", `/v1/pair/${slot}`, { ...C, body: { ch: a.ch, hello: fakeBox() } })).status, 201);
  const b = await setupChannel(r1, { devices: 1 });
  assert.equal((await call(r1.base, "DELETE", `/v1/channels/${b.ch}`, { token: b.computer.token })).status, 204);

  // Ten minutes on, the slot is gone and the rest is still there.
  const r2 = await restart({ start: t0 + 10 * MINUTE });
  expectError(await call(r2.base, "GET", `/v1/pair/${slot}`), 404, "not_found");
  assert.equal((await call(r2.base, "GET", `/v1/ch/${a.ch}/cmd`, C)).json.commands.length, 1);
  expectError(await getState(r2, b, b.phones[0]), 410, "gone", ["unlinkedAt"]);

  // Thirty days on, the command and the marker are gone too; the state stays.
  const r3 = await restart({ start: t0 + 30 * DAY });
  const st = await getState(r3, a, p);
  assert.equal(st.status, 200);
  assert.equal(st.json.lastCmdSeq, 1);
  assert.deepEqual((await call(r3.base, "GET", `/v1/ch/${a.ch}/cmd`, C)).json.commands, []);
  expectError(await getState(r3, b, b.phones[0]), 401, "unauthorized");
});

test("a wiped data folder gives a new instance ID and setup code; the computer sees 404 and sets its channel up again", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const old = { instance: r1.relay.instance, setupCode: r1.relay.setupCode };
  const a = await setupChannel(r1, { devices: 1 });
  const [p] = a.phones;
  await restart.wipe();

  const r2 = await restart();
  assert.equal(r2.dataDir, r1.dataDir);
  assert.equal(r2.relay.firstStart, true);
  assert.notEqual(r2.relay.instance, old.instance);
  assert.notEqual(r2.relay.setupCode, old.setupCode);

  const lost = await call(r2.base, "POST", `/v1/ch/${a.ch}/presence`, { token: a.computer.token, body: { awake: true } });
  expectError(lost, 404, "not_found");
  assert.equal(lost.headers.get("x-tc-instance"), r2.relay.instance);
  expectError(await getState(r2, a, p), 401, "unauthorized");

  // Without TC_SETUP_CODE, the code the computer kept is the old one, so the new code has to be
  // typed in on the computer (the next test pins the code instead).
  const recreate = (setupCode) => call(r2.base, "PUT", `/v1/channels/${a.ch}`, { token: a.computer.token, body: { setupCode, tokenHash: a.computer.hash } });
  expectError(await recreate(old.setupCode), 403, "forbidden");
  assert.equal((await recreate(r2.relay.setupCode)).status, 201);
  assert.equal((await call(r2.base, "PUT", `/v1/ch/${a.ch}/devices`, { token: a.computer.token, body: { devices: [{ id: p.id, tokenHash: p.hash }] } })).status, 204);
  const box = fakeBox();
  assert.equal((await call(r2.base, "PUT", `/v1/ch/${a.ch}/state`, { token: a.computer.token, body: { seq: 9, copies: { [p.id]: box } } })).status, 204);
  assert.equal((await getState(r2, a, p)).json.box, box, "the phone's token works again");
});

test("with a pinned setup code (TC_SETUP_CODE), a wiped data folder gets a new instance ID but keeps the code, so the computer recovers by itself", async (t) => {
  const restart = relays(t);
  const r1 = await restart({ setupCode: "abcd-efgh-jkmn" });
  assert.equal(r1.relay.setupCode, "ABCDEFGHJKMN", "normalised like a typed code");
  assert.equal(JSON.parse(await readFile(join(r1.dataDir, "server.json"), "utf8")).setupCode, "ABCDEFGHJKMN");
  const a = await setupChannel(r1, { devices: 1 });
  const [p] = a.phones;
  const oldInstance = r1.relay.instance;
  await restart.wipe();

  const r2 = await restart({ setupCode: "ABCD-EFGH-JKMN" });
  assert.notEqual(r2.relay.instance, oldInstance, "computers can still tell the data is gone");
  assert.equal(r2.relay.setupCode, "ABCDEFGHJKMN");
  // §6.1 "Server reset": 404, then re-create with the code it kept, re-register, upload.
  expectError(await call(r2.base, "POST", `/v1/ch/${a.ch}/presence`, { token: a.computer.token, body: { awake: true } }), 404, "not_found");
  const recreated = await call(r2.base, "PUT", `/v1/channels/${a.ch}`, { token: a.computer.token, body: { setupCode: "ABCD-EFGH-JKMN", tokenHash: a.computer.hash } });
  assert.equal(recreated.status, 201);
  assert.equal((await call(r2.base, "PUT", `/v1/ch/${a.ch}/devices`, { token: a.computer.token, body: { devices: [{ id: p.id, tokenHash: p.hash }] } })).status, 204);
  const box = fakeBox();
  assert.equal((await call(r2.base, "PUT", `/v1/ch/${a.ch}/state`, { token: a.computer.token, body: { seq: 2, copies: { [p.id]: box } } })).status, 204);
  assert.equal((await getState(r2, a, p)).json.box, box);
});

test("pinning a different setup code on an existing folder replaces the saved code and keeps the instance ID; a malformed pin is refused", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const { instance, setupCode: generated } = r1.relay;
  const r2 = await restart({ setupCode: "0000-1111-2222" });
  assert.equal(r2.relay.instance, instance);
  assert.equal(r2.relay.setupCode, "000011112222");
  assert.notEqual(r2.relay.setupCode, generated);
  const fresh = newToken();
  const put = (setupCode) => call(r2.base, "PUT", `/v1/channels/${channelId()}`, { token: fresh.token, body: { setupCode, tokenHash: fresh.hash } });
  expectError(await put(generated), 403, "forbidden");
  assert.equal((await put("oooo-iiii-2222")).status, 201);
  // Without the pin, the replaced code is what the folder now holds.
  const r3 = await restart();
  assert.equal(r3.relay.setupCode, "000011112222");
  assert.equal(r3.relay.instance, instance);

  await restart.stop();
  for (const bad of ["ABCDEFGHJKM", "ABCDEFGHJKMNP", "UUUUUUUUUUUU"]) {
    await assert.rejects(Relay.open({ dataDir: r3.dataDir, setupCode: bad, log: quiet }), /12 letters and numbers/, bad);
  }
});

test("node server.mjs --setup-code shows the data folder's code, formatted, or the pinned one; it never makes a folder", async (t) => {
  const top = await mkdtemp(join(tmpdir(), "tc-relay-test-"));
  t.after(() => rm(top, { recursive: true, force: true }));
  const dataDir = join(top, "data");
  const server = fileURLToPath(new URL("../server.mjs", import.meta.url));
  const { NODE_TEST_CONTEXT, TC_SETUP_CODE, ...inherited } = process.env;
  const run = (env = {}) =>
    promisify(execFile)(process.execPath, [server, "--setup-code"], { env: { ...inherited, TC_DATA_DIR: dataDir, ...env }, timeout: 10_000 }).then(
      ({ stdout }) => ({ code: 0, stdout: stdout.trim() }),
      (e) => ({ code: e.code, stdout: e.stdout.trim(), stderr: e.stderr }),
    );

  const none = await run();
  assert.notEqual(none.code, 0, "no data folder yet");
  assert.equal(none.stdout, "");
  assert.deepEqual(await readdir(top), [], "and it didn't make one");

  const r = await startRelay({ dataDir });
  const saved = r.relay.setupCode;
  await r.stop();
  assert.deepEqual(await run(), { code: 0, stdout: saved.match(/.{4}/g).join("-") });
  assert.deepEqual(await run({ TC_SETUP_CODE: "wxyz-wxyz-wxyz" }), { code: 0, stdout: "WXYZ-WXYZ-WXYZ" });
  assert.notEqual((await run({ TC_SETUP_CODE: "too-short" })).code, 0);
});

test("losing the channel files but not server.json: same instance and setup code, so the computer can recover by itself", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const a = await setupChannel(r1, { devices: 1 });
  const [p] = a.phones;
  await restart.stop();
  await rm(join(r1.dataDir, "channels"), { recursive: true, force: true });

  const r2 = await restart();
  assert.equal(r2.relay.instance, r1.relay.instance);
  assert.equal(r2.relay.setupCode, r1.relay.setupCode);
  expectError(await call(r2.base, "POST", `/v1/ch/${a.ch}/presence`, { token: a.computer.token, body: { awake: true } }), 404, "not_found");
  const recreated = await call(r2.base, "PUT", `/v1/channels/${a.ch}`, { token: a.computer.token, body: { setupCode: r1.relay.setupCode, tokenHash: a.computer.hash } });
  assert.equal(recreated.status, 201);
  assert.equal((await call(r2.base, "PUT", `/v1/ch/${a.ch}/devices`, { token: a.computer.token, body: { devices: [{ id: p.id, tokenHash: p.hash }] } })).status, 204);
  assert.equal((await getState(r2, a, p)).status, 204);
});

test("an unreadable channel file is moved aside and doesn't stop the relay starting", async (t) => {
  const restart = relays(t);
  const r1 = await restart();
  const a = await setupChannel(r1, { devices: 1 });
  const b = await setupChannel(r1, { devices: 1 });
  await restart.stop();
  const files = await readdir(join(r1.dataDir, "channels"));
  const metas = files.filter((f) => /^[0-9a-f]{32}\.json$/.test(f));
  assert.equal(metas.length, 2);
  await writeFile(join(r1.dataDir, "channels", metas[0]), "{ this is not json");

  const r2 = await restart();
  const after = await readdir(join(r2.dataDir, "channels"));
  assert.ok(after.some((f) => f.startsWith(metas[0] + ".unreadable-")), "moved aside: " + after.join(", "));
  const alive = [];
  for (const s of [a, b]) {
    const res = await call(r2.base, "POST", `/v1/ch/${s.ch}/presence`, { token: s.computer.token, body: { awake: true } });
    alive.push(res.status);
  }
  assert.deepEqual(alive.sort(), [204, 404], "one channel lost, the other fine");
});
