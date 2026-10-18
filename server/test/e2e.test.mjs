// End to end: fake computer ↔ the real server (as its own process) ↔ fake phones running the
// parent app's protocol code. Covers every command, then what must fail: a replayed command,
// a flipped signature bit, a stale "at", an unknown device, a removed device, and the server
// restarting (and losing its data) mid-run.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { FakeComputer } from "../tools/fake-computer.mjs";
import { FakePhone, runAll } from "../tools/fake-phone.mjs";
import * as lc from "../../parent/js/linkcrypto.js";
import * as phone from "../../parent/js/phone.js";

const SERVER = fileURLToPath(new URL("../server.mjs", import.meta.url));
const MINUTE = 60_000;

let dataDir, port, base, proc, setupCode, fc, loop, mom, dad;

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function startServer(env = {}) {
  proc = spawn(process.execPath, [SERVER], {
    env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", TC_DATA_DIR: dataDir, TC_LOG_REQUESTS: "0", ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("server didn't start: " + out)), 10_000);
    proc.stdout.on("data", (d) => {
      out += d;
      if (out.includes("listening on")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.stderr.on("data", (d) => (out += d));
    proc.once("exit", (code) => reject(new Error(`server exited (${code}): ${out}`)));
  });
}

async function stopServer() {
  const p = proc;
  proc = null;
  if (!p || p.exitCode !== null) return;
  const exited = new Promise((resolve) => p.once("exit", resolve));
  p.kill("SIGTERM");
  await exited;
}

const instanceOf = async () => (await fetch(base + "/v1/health")).headers.get("X-TC-Instance");

before(async () => {
  dataDir = await mkdtemp(join(tmpdir(), "tc-e2e-"));
  port = await freePort();
  base = `http://127.0.0.1:${port}`;
  await startServer();
  setupCode = JSON.parse(await readFile(join(dataDir, "server.json"), "utf8")).setupCode;
  fc = new FakeComputer({ server: base, setupCode, name: "Test Mac", wait: 3 });
  await fc.init();
  await fc.connect();
  loop = fc.run();
});

after(async () => {
  fc?.stop();
  await loop;
  await stopServer();
  await rm(dataDir, { recursive: true, force: true });
});

async function pairPhone(name) {
  const p = new FakePhone({ server: base, name });
  const pairing = await fc.startPairing();
  await p.pair(pairing.formatted.toLowerCase()); // typed any old way
  const outcome = await pairing.result;
  assert.equal(outcome.ok, true, outcome.why);
  return p;
}

test("pairing: both screens show the same code, and the phone keeps its keys inside", async () => {
  mom = await pairPhone("Mom's iPhone");
  assert.match(mom.comparison, /^\d{6}$/);
  assert.equal(mom.comparison, fc.lastComparison);
  assert.equal(mom.computer.linkKey.extractable, false);
  assert.equal(mom.computer.signKey.extractable, false);
  assert.equal(mom.computer.computerName, "Test Mac");
  assert.equal(fc.devices.length, 1);
  assert.equal(fc.devices[0].name, "Mom's iPhone");
  dad = await pairPhone("Dad's Pixel");
  assert.equal(fc.devices.length, 2);
  const s = await mom.waitFor((st) => st.devices.length === 2 && st, { what: "both phones in the state" });
  assert.deepEqual(s.devices.map((d) => d.name).sort(), ["Dad's Pixel", "Mom's iPhone"]);
});

test("pairing: a wrong code finds nothing, and a second phone committing stops the pairing", async () => {
  const stranger = new FakePhone({ server: base, name: "Stranger" });
  await assert.rejects(stranger.pair("ZZZZZ-ZZZZZ"), (e) => e.code === "bad_code");

  // Two phones race for one code: the computer must stop, and nobody gets paired.
  const pairing = await fc.startPairing({ approve: () => new Promise((r) => setTimeout(() => r(true), 1500)) });
  const a = new FakePhone({ server: base, name: "Phone A" });
  const b = new FakePhone({ server: base, name: "Phone B" });
  const results = await Promise.allSettled([a.pair(pairing.code), b.pair(pairing.code)]);
  const outcome = await pairing.result;
  assert.equal(outcome.ok, false);
  assert.match(outcome.why, /Two phones/);
  assert.ok(results.every((r) => r.status === "rejected"), "neither phone may finish pairing");
  assert.equal(fc.devices.length, 2);
});

test("every command type does what it says", async () => {
  const checks = await runAll(mom);
  const failed = checks.filter((c) => !c.ok);
  assert.deepEqual(failed, [], failed.map((c) => `${c.name}: ${c.detail}`).join("\n"));
  assert.ok(checks.length >= 30);
});

test("the phone sees delivery and liveness from the server's clock", async () => {
  const sent = await mom.send("setPenalty", { minutes: 15 });
  await mom.result(sent);
  assert.ok(mom.meta.ackedUpTo >= sent.seq, "acked");
  assert.equal(phone.commandPhase(sent, { state: mom.state, meta: mom.meta, live: mom.live, deviceId: mom.computer.deviceId }).phase, "applied");
  assert.equal(mom.live.computerAwake, true);
  assert.ok(mom.live.serverTime - mom.live.computerSeen < 5_000, "seen just now");

  await fc.sleep();
  const asleep = await mom.waitFor(() => mom.live.computerAwake === false, { what: "asleep" });
  assert.ok(asleep);
  const queued = await mom.send("setPenalty", { minutes: 20 });
  await mom.refresh();
  assert.equal(phone.commandPhase(queued, { state: mom.state, meta: mom.meta, live: mom.live, deviceId: mom.computer.deviceId }).phase, "asleep");
  await fc.wake();
  const r = await mom.result(queued);
  assert.equal(r.outcome, "applied");
  assert.equal(mom.live.computerAwake, true);
});

test("a replayed command is rejected and reports the counter", async () => {
  const sent = await mom.send("setPenalty", { minutes: 25 });
  assert.equal((await mom.result(sent)).outcome, "applied");
  await phone.postCommand(mom.computer, sent.box); // the exact same bytes again
  const replay = await mom.waitFor((s) => s.results.find((r) => r.id === sent.id && r.reason === "replayed"), { what: "the replay's result" });
  assert.equal(replay.outcome, "rejected");
  assert.equal(replay.last, sent.n, "the last counter accepted, so the phone can catch up");
  assert.equal(phone.resultFor(mom.state, mom.computer.deviceId, sent.id).outcome, "applied", "the replay doesn't hide the real answer");
  assert.equal(mom.state.settings.penaltyMinutes, 25);
});

test("a flipped signature bit is caught before anything is applied", async () => {
  const c = mom.computer;
  const body = lc.commandBody({ channel: c.channel, deviceId: c.deviceId, n: Date.now() + 10, at: Date.now(), id: lc.uuid(), type: "setPenalty", args: { minutes: 600 } });
  const bytes = lc.utf8(body);
  const sig = await lc.sign(c.signKey, bytes);
  sig[7] ^= 0x10;
  const box = lc.b64(await lc.seal(c.linkKey, lc.concat(sig, bytes), lc.commandAad(c.channel, c.deviceId)));
  const before = mom.state.results.length;
  await phone.postCommand(c, box);
  const flag = await mom.waitFor((s) => s.flags.find((f) => f.kind === "badCommand"), { what: "the tamper flag" });
  assert.ok(flag.text.length > 0);
  const r = mom.state.results.slice(before).find((x) => x.reason === "bad_signature");
  assert.equal(r.outcome, "rejected");
  assert.equal(r.id, "", "nothing from an unverified body is trusted");
  assert.equal(mom.state.settings.penaltyMinutes, 25, "not applied");
  // A box sealed with the wrong key doesn't open at all.
  const wrongKey = lc.b64(await lc.seal(lc.randomBytes(32), lc.concat(sig, bytes), lc.commandAad(c.channel, c.deviceId)));
  await phone.postCommand(c, wrongKey);
  await mom.waitFor((s) => s.results.slice(before).some((x) => x.reason === "bad_box"), { what: "bad_box" });
  fc.clearFlags();
});

test("a command made more than 10 minutes before the server got it is stale", async () => {
  const sent = await mom.send("setPenalty", { minutes: 90 }, { at: Date.now() - 11 * MINUTE });
  const r = await mom.result(sent);
  assert.equal(r.outcome, "rejected");
  assert.equal(r.reason, "stale");
  assert.equal(mom.state.settings.penaltyMinutes, 25);
  // Nine minutes is still fresh. (Not a setting: an older setting change would lose to newer ones.)
  const ok = await mom.send("message", { text: "Sent from the car" }, { at: Date.now() - 9 * MINUTE });
  assert.equal((await mom.result(ok)).outcome, "applied");
});

test("settings: the change made last wins, whatever order they arrive in", async () => {
  const t = Date.now();
  const newer = await mom.send("setExtensions", { enabled: false }, { at: t });
  assert.equal((await mom.result(newer)).outcome, "applied");
  const older = await dad.send("setExtensions", { enabled: true }, { at: t - 30_000 });
  const r = await dad.result(older);
  assert.equal(r.outcome, "noop");
  assert.equal(dad.state.settings.extensionsEnabled, false);
  await mom.run("setExtensions", { enabled: true });
});

test("a device the computer never paired is rejected", async () => {
  const rogueToken = lc.randomBytes(32);
  const rogueId = lc.uuid();
  await fc.registerExtraDevice(rogueId, lc.b64(await lc.sha256(rogueToken)));
  const signing = await lc.newSigningKeys();
  const rogue = {
    id: "rogue", origin: base, channel: fc.channel, deviceId: rogueId, deviceToken: lc.b64(rogueToken),
    linkKey: lc.randomBytes(32), signKey: signing.privateKey,
  };
  const store = { getCounter: async () => 0, setCounter: async () => {} };
  const sent = await phone.sendCommand({ computer: rogue, store, type: "lock", args: { until: null, strength: "all" } });
  assert.ok(sent.seq > 0, "the server took it: it knows the token");
  const r = await mom.waitFor((s) => s.results.find((x) => x.dev === rogueId), { what: "the rogue's result" });
  assert.equal(r.outcome, "rejected");
  assert.equal(r.reason, "unknown_device");
  assert.equal(mom.state.access.mode, "normal", "nothing was locked");
  await fc.registerDevices();
  const gone = await phone.fetchState({ computer: rogue });
  assert.equal(gone.kind, "unauthorized");
});

test("a removed phone is cut off, even for a command it queued before", async () => {
  const sent = await dad.send("message", { text: "From Dad" });
  assert.equal((await dad.result(sent)).outcome, "applied");

  // Dad queues a command while the computer is busy; Mom's removal reaches the computer first.
  fc.paused = true;
  fc.pollAbort?.abort();
  await new Promise((r) => setTimeout(r, 200));
  const removal = await mom.send("removeDevice", { id: dad.computer.deviceId });
  const late = await dad.send("lock", { until: null, strength: "all" });
  assert.ok(late.seq > removal.seq);
  fc.paused = false;

  assert.equal((await mom.result(removal)).outcome, "applied");
  const r = await mom.waitFor((s) => s.results.find((x) => x.dev === dad.computer.deviceId && x.reason === "unknown_device"), { what: "Dad's late command" });
  assert.equal(r.outcome, "rejected");
  assert.equal(mom.state.access.mode, "normal");
  assert.ok(!mom.state.devices.some((d) => d.id === dad.computer.deviceId));

  const after = await phone.fetchState({ computer: dad.computer });
  assert.equal(after.kind, "unauthorized");
  await assert.rejects(dad.send("normal", {}), (e) => e.code === "unauthorized");
});

test("the server restarts mid-run: queued commands and state survive, and the computer reconnects", async () => {
  const instance = await instanceOf();
  fc.paused = true;
  fc.pollAbort?.abort();
  await new Promise((r) => setTimeout(r, 200));
  const queued = await mom.send("setPenalty", { minutes: 40 });

  await stopServer();
  await assert.rejects(mom.send("setPenalty", { minutes: 41 }), (e) => e.code === "network");
  await startServer();
  assert.equal(await instanceOf(), instance, "same instance after a restart");

  // The phone reads the saved state before the computer is back.
  mom.reset();
  const saved = await mom.refresh();
  assert.equal(saved.kind, "state");
  fc.paused = false;
  const r = await mom.result(queued);
  assert.equal(r.outcome, "applied");
  assert.equal(mom.state.settings.penaltyMinutes, 40);
  const fresh = await mom.run("setPenalty", { minutes: 35 });
  assert.equal(fresh.result.outcome, "applied");
});

test("the server loses its data: the computer links again and the phone carries on", async () => {
  const instance = await instanceOf();
  await stopServer();
  await rm(dataDir, { recursive: true, force: true });
  // Keep the setup code (TC_SETUP_CODE) so the computer's saved one still works.
  await startServer({ TC_SETUP_CODE: setupCode });
  const newInstance = await instanceOf();
  assert.notEqual(newInstance, instance);

  const lastSeq = mom.lastSeq;
  const back = await mom.waitFor((s) => s.seq > lastSeq && s, { timeout: 20_000, what: "the computer to link again" });
  assert.ok(back.devices.some((d) => d.id === mom.computer.deviceId));
  const r = await mom.run("message", { text: "Still here?" });
  assert.equal(r.result.outcome, "applied");
});

test("unlinking the computer gives phones 410 with the time", async () => {
  const res = await fc.api("DELETE", `/v1/channels/${fc.channel}`);
  assert.equal(res.status, 204);
  const r = await phone.fetchState({ computer: mom.computer });
  assert.equal(r.kind, "gone");
  assert.ok(r.unlinkedAt > 0);
  await assert.rejects(mom.send("normal", {}), (e) => e.code === "gone");
  fc.stop();
});
