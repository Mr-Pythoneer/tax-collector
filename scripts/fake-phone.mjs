// A pretend parent phone that follows docs/parent-link-v1.md, for testing the computer's side end to end.
//   node scripts/fake-phone.mjs <server> <pairing code>
// It pairs, sends every kind of command, checks the computer's answers in its state, then tries a replayed
// command and a forged signature. Prints PASS/FAIL lines and exits non-zero on any failure.
import { inflateRawSync } from "node:zlib";
import { b64, unb64, normaliseCode, hkdf, seal, open } from "../spec/vectors/gen.mjs";

const [server, code] = process.argv.slice(2);
// Never hang a test run: give up after three minutes.
setTimeout(() => { console.log("FAIL  timed out"); process.exit(1); }, 180_000).unref();
const subtle = globalThis.crypto.subtle;
const te = new TextEncoder(), td = new TextDecoder();
const ascii = (s) => te.encode(s);
const cat = (...p) => Uint8Array.from(p.flatMap((x) => [...x]));
const sha256 = async (b) => new Uint8Array(await subtle.digest("SHA-256", b));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok || !detail ? "" : ": " + detail}`);
  if (!ok) failures++;
};

async function call(method, path, body, token) {
  const res = await fetch(server + path, {
    method, headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : {} };
}

// --- Pairing (§4) ---
const ikm = te.encode(normaliseCode(code));
const slot = b64(await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair slot"), 16));
const pairKey = await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair key"), 32);
const pairAad = ascii("tc v1 pair|" + slot);
const sealJson = async (obj) => b64(await seal(pairKey, crypto.getRandomValues(new Uint8Array(12)), te.encode(JSON.stringify(obj)), pairAad));

let hello;
for (let i = 0; i < 20 && !hello; i++) {
  const r = await call("GET", `/v1/pair/${slot}`);
  if (r.status === 200) hello = JSON.parse(td.decode(await open(pairKey, unb64(r.body.hello), pairAad)));
  else await sleep(500);
}
check("pairing: the computer's hello opens with the code", hello?.t === "hello" && !!hello.ch);
const channel = hello.ch;

const sign = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
const dh = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
const signPub = new Uint8Array(await subtle.exportKey("raw", sign.publicKey));
const dhPub = new Uint8Array(await subtle.exportKey("raw", dh.publicKey));
const phoneNonce = crypto.getRandomValues(new Uint8Array(32));
const token = crypto.getRandomValues(new Uint8Array(32));
const tokenHash = await sha256(token);
const name = "Test Phone";
const commit = b64(await sha256(cat(ascii("tc v1 commit"), signPub, dhPub, phoneNonce, tokenHash, te.encode(name))));
await call("POST", `/v1/pair/${slot}/toComputer`, { box: await sealJson({ t: "commit", commit }) });

async function fromComputer(want, after = 0) {
  for (let i = 0; i < 30; i++) {
    const r = await call("GET", `/v1/pair/${slot}/toPhone?after=${after}&wait=5`);
    for (const m of r.body.messages || []) {
      const msg = JSON.parse(td.decode(await open(pairKey, unb64(m.box), pairAad)));
      if (msg.t === want || msg.t === "rejected") return { msg, n: m.n };
    }
    await sleep(200);
  }
  return {};
}
const nonceMsg = await fromComputer("nonce");
check("pairing: the computer sends its nonce only after the commit", nonceMsg.msg?.t === "nonce");
await call("POST", `/v1/pair/${slot}/toComputer`, { box: await sealJson({
  t: "reveal", signKey: b64(signPub), dhKey: b64(dhPub), nonce: b64(phoneNonce), tokenHash: b64(tokenHash), name,
}) });
const h = await sha256(cat(ascii("tc v1 sas"), unb64(nonceMsg.msg.nonce), phoneNonce, unb64(hello.dhKey), signPub, dhPub));
const sas = String(new DataView(h.buffer).getUint32(0, false) % 1000000).padStart(6, "0");
console.log(`      comparison code on this phone: ${sas.slice(0, 3)} ${sas.slice(3)}`);
const done = await fromComputer("done", nonceMsg.n);
check("pairing: the computer approves and names this phone", done.msg?.t === "done" && !!done.msg.dev, JSON.stringify(done.msg));
const dev = done.msg.dev;
const computerPub = await subtle.importKey("raw", unb64(hello.dhKey), { name: "ECDH", namedCurve: "P-256" }, false, []);
const shared = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: computerPub }, dh.privateKey, 256));
const linkKey = await hkdf(shared, unb64(channel), ascii("tc v1 link|" + dev), 32);
const tokenText = b64(token);

// --- State and commands (§5) ---
let lastSeq = 0;
async function state(minSeq = 0) {
  for (let i = 0; i < 40; i++) {
    const r = await call("GET", `/v1/ch/${channel}/state`, null, tokenText);
    if (r.status === 200 && r.body.seq > minSeq) {
      const plain = await open(linkKey, unb64(r.body.box), ascii(`tc v1 state|${channel}|${dev}`));
      const s = JSON.parse(td.decode(inflateRawSync(plain)));
      lastSeq = s.seq;
      return { s, meta: r.body };
    }
    await sleep(500);
  }
  return {};
}
let counter = Date.now();
async function command(type, args, { tamper = false, replayOf = null } = {}) {
  const id = crypto.randomUUID();
  counter = Math.max(counter + 1, Date.now());
  const body = replayOf ?? JSON.stringify({ v: 1, ch: channel, dev, n: counter, at: Date.now(), id, type, args });
  const sig = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, sign.privateKey, te.encode(body)));
  if (tamper) sig[7] ^= 1;
  const box = await seal(linkKey, crypto.getRandomValues(new Uint8Array(12)), cat(sig, te.encode(body)), ascii(`tc v1 cmd|${channel}|${dev}`));
  const r = await call("POST", `/v1/ch/${channel}/cmd`, { box: b64(box) }, tokenText);
  return { id, body, sent: r.status === 201 };
}
async function result(id, n) {
  for (let i = 0; i < 40; i++) {
    const { s } = await state(lastSeq);
    const hit = s?.results?.find((x) => (id && x.id === id) || (n && x.n === n));
    if (hit) return { r: hit, s };
  }
  return {};
}

const first = await state(0);
check("state: arrives, opens and inflates", first.s?.v === 1 && first.s.computer?.platform === "mac");
check("state: the device list shows this phone", first.s?.devices?.some((d) => d.id === dev && d.name === name));
check("state: no secrets in it", !JSON.stringify(first.s).includes("podium") && !JSON.stringify(first.s).includes("claude-token"));

let c = await command("lock", { until: Date.now() + 30 * 60_000, strength: "homework", note: "Homework first" });
let got = await result(c.id);
check("lock: applied", got.r?.outcome === "applied", JSON.stringify(got.r));
check("lock: state says locked by this phone", got.s?.access?.mode === "locked" && got.s.access.by === name && got.s.lock?.locked === true);

c = await command("free", { until: Date.now() + 10 * 60_000 });
got = await result(c.id);
check("free: unlocked until a time", got.r?.outcome === "applied" && got.s?.access?.mode === "free" && got.s.lock?.locked === false);

c = await command("normal", {});
got = await result(c.id);
check("normal: back to the usual rules", got.r?.outcome === "applied" && got.s?.access?.mode === "normal");

const taskId = crypto.randomUUID();
c = await command("addTask", { task: { id: taskId, title: "Read chapter 4", details: "Pages 60-80", due: Date.now() + 3 * 86400_000 } });
got = await result(c.id);
check("addTask: the task shows up", got.r?.outcome === "applied" && got.s?.tasks?.some((t) => t.id === taskId && t.title === "Read chapter 4"));
c = await command("addTask", { task: { id: taskId, title: "Read chapter 4", details: "", due: Date.now() + 3 * 86400_000 } });
got = await result(c.id);
check("addTask: sending it twice adds it once", got.r?.outcome === "noop" && got.s?.tasks?.filter((t) => t.id === taskId).length === 1);
c = await command("editTask", { id: taskId, title: "Read chapter 5" });
got = await result(c.id);
check("editTask: renamed", got.s?.tasks?.some((t) => t.id === taskId && t.title === "Read chapter 5"));
c = await command("excuseTask", { id: taskId });
got = await result(c.id);
check("excuseTask: excused", got.s?.tasks?.some((t) => t.id === taskId && t.status === "excused"));
c = await command("deleteTask", { id: taskId });
got = await result(c.id);
check("deleteTask: gone", got.r?.outcome === "applied" && !got.s?.tasks?.some((t) => t.id === taskId));

const repeatId = crypto.randomUUID();
c = await command("addRepeat", { repeat: { id: repeatId, title: "Piano practice", details: "", unit: "days", interval: 2, weekdays: [], minuteOfDay: 19 * 60, startDate: new Date().toISOString().slice(0, 10) } });
got = await result(c.id);
check("addRepeat: the repeat and its first copy show up", got.s?.repeats?.some((r) => r.id === repeatId) && got.s?.tasks?.some((t) => t.repeatId === repeatId));
c = await command("stopRepeat", { id: repeatId });
got = await result(c.id);
check("stopRepeat: stopped", got.r?.outcome === "applied" && !got.s?.repeats?.some((r) => r.id === repeatId));

c = await command("blockApp", { app: { id: "org.example.game", name: "Example Game" } });
got = await result(c.id);
check("blockApp: listed as blocked", got.s?.apps?.blocked?.some((a) => a.id === "org.example.game"));
c = await command("unblockApp", { app: { id: "org.example.game", name: "Example Game" } });
got = await result(c.id);
check("unblockApp: unblocked", !got.s?.apps?.blocked?.some((a) => a.id === "org.example.game"));
c = await command("allowApp", { app: { id: "org.example.notes", name: "Notes Thing" } });
got = await result(c.id);
check("allowApp: allowed during locks, with its name", got.s?.apps?.allowed?.some((a) => a.id === "org.example.notes" && a.name === "Notes Thing"));

c = await command("setPenalty", { minutes: 45 });
got = await result(c.id);
check("setPenalty: 45 minutes", got.s?.settings?.penaltyMinutes === 45);
c = await command("setExtensions", { enabled: false });
got = await result(c.id);
check("setExtensions: off", got.s?.settings?.extensionsEnabled === false);
c = await command("message", { text: "Dinner at 6!" });
got = await result(c.id);
check("message: shown", got.s?.message?.text === "Dinner at 6!" && got.s.message.by === name);
c = await command("makeCoffee", {});
got = await result(c.id);
check("unknown command: unsupported", got.r?.outcome === "unsupported");

// --- Attacks ---
const replay = await command("setPenalty", { minutes: 5 });
await result(replay.id);
const again = await command("setPenalty", {}, { replayOf: replay.body });
got = await result(replay.id);
let replayed = got.s?.results?.filter((x) => x.id === replay.id) ?? [];
for (let i = 0; i < 10 && replayed.length < 2; i++) {
  const { s } = await state(lastSeq);
  replayed = s?.results?.filter((x) => x.id === replay.id) ?? [];
}
check("replay: the same command twice is rejected the second time", replayed.length === 2 && replayed[1].outcome === "rejected" && replayed[1].reason === "replayed" && replayed[1].last >= replayed[1].n, JSON.stringify(replayed));
const forged = await command("free", { until: Date.now() + 86400_000 }, { tamper: true });
let after;
for (let i = 0; i < 20; i++) {
  ({ s: after } = await state(0));
  if (after?.results?.some((x) => x.reason === "bad_signature")) break;
  await sleep(500);
}
check("forgery: a bad signature changes nothing", after?.access?.mode !== "free" && after?.results?.some((x) => x.reason === "bad_signature"));
check("forgery: it's flagged to parents", after?.flags?.some((f) => f.kind === "badCommand"));

c = await command("removeDevice", { id: dev });
let gone = { status: 0 };
for (let i = 0; i < 40 && gone.status !== 401; i++) {
  await sleep(500);
  gone = await call("GET", `/v1/ch/${channel}/state`, null, tokenText);
}
check("removeDevice: this phone removed itself, and its token stopped working", gone.status === 401, String(gone.status));

console.log(failures ? `${failures} failed.` : "All end-to-end checks passed.");
process.exit(failures ? 1 : 0);
