// Checks spec/vectors/v1.json from scratch with WebCrypto: the reference for what every
// implementation must agree with. Run: node --test spec/vectors/check.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { b64, unb64, normaliseCode, hkdf, seal, open } from "./gen.mjs";

const V = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "v1.json"), "utf8"));
const subtle = globalThis.crypto.subtle;
const te = new TextEncoder();
const td = new TextDecoder();
const ascii = (s) => te.encode(s);
const cat = (...p) => Uint8Array.from(p.flatMap((x) => [...x]));
const sha256 = async (b) => new Uint8Array(await subtle.digest("SHA-256", b));

test("pairing codes normalise", () => {
  for (const [input, want] of V.normalise) assert.equal(normaliseCode(input), want);
});

test("slot and pairing key come from the code", async () => {
  const ikm = te.encode(V.pairing.normalised);
  assert.equal(b64(await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair slot"), 16)), V.pairing.slot);
  assert.equal(b64(await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair key"), 32)), V.pairing.pairKey);
});

test("hello box seals and opens exactly", async () => {
  const p = V.pairing;
  const sealed = await seal(unb64(p.pairKey), unb64(p.hello.nonce), te.encode(p.hello.plaintext), ascii(p.aad));
  assert.equal(b64(sealed), p.hello.box);
  assert.equal(td.decode(await open(unb64(p.pairKey), unb64(p.hello.box), ascii(p.aad))), p.hello.plaintext);
  await assert.rejects(open(unb64(p.pairKey), unb64(p.hello.box), ascii(p.aad + "x")));
});

test("commitment and comparison code", async () => {
  const p = V.pairing;
  const commit = await sha256(cat(ascii("tc v1 commit"), unb64(p.phone.signKey.public), unb64(p.phone.dhKey.public),
    unb64(p.phone.nonce), unb64(p.phone.tokenHash), te.encode(p.phone.name)));
  assert.equal(b64(commit), p.commit);
  assert.equal(b64(await sha256(unb64(p.phone.token))), p.phone.tokenHash);
  const h = await sha256(cat(ascii("tc v1 sas"), unb64(p.computer.nonce), unb64(p.phone.nonce),
    unb64(p.computer.dhKey.public), unb64(p.phone.signKey.public), unb64(p.phone.dhKey.public)));
  assert.equal(String(new DataView(h.buffer).getUint32(0, false) % 1000000).padStart(6, "0"), p.sas);
});

test("link key from either end", async () => {
  const p = V.pairing, L = V.link;
  const imp = (k) => subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: k.x, y: k.y, d: k.d }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const pub = (raw) => subtle.importKey("raw", unb64(raw), { name: "ECDH", namedCurve: "P-256" }, false, []);
  const a = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: await pub(p.phone.dhKey.public) }, await imp(p.computer.dhKey), 256));
  const b = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: await pub(p.computer.dhKey.public) }, await imp(p.phone.dhKey), 256));
  assert.equal(b64(a), L.shared);
  assert.equal(b64(b), L.shared);
  assert.equal(b64(await hkdf(a, unb64(L.channel), ascii("tc v1 link|" + L.deviceId), 32)), L.linkKey);
});

test("command opens, and only the true signature verifies", async () => {
  const C = V.command;
  const opened = await open(unb64(V.link.linkKey), unb64(C.box), ascii(C.aad));
  assert.equal(b64(opened.slice(0, 64)), C.signature);
  assert.equal(td.decode(opened.slice(64)), C.body);
  const key = await subtle.importKey("raw", unb64(V.pairing.phone.signKey.public), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const alg = { name: "ECDSA", hash: "SHA-256" };
  assert.ok(await subtle.verify(alg, key, unb64(C.signature), te.encode(C.body)));
  assert.ok(!(await subtle.verify(alg, key, unb64(C.tamperedSignature), te.encode(C.body))));
  assert.ok(!(await subtle.verify(alg, key, unb64(C.signature), te.encode(C.body.replace("homework", "all")))));
  const parsed = JSON.parse(C.body);
  assert.equal(parsed.ch, V.link.channel);
  assert.equal(parsed.dev, V.link.deviceId);
});

test("state opens and inflates", async () => {
  const S = V.state;
  const opened = await open(unb64(V.link.linkKey), unb64(S.box), ascii(S.aad));
  assert.equal(b64(opened), S.deflated);
  assert.equal(td.decode(inflateRawSync(opened)), S.json);
  await assert.rejects(open(unb64(V.link.linkKey), unb64(S.box), ascii("tc v1 state|other|" + V.link.deviceId)));
});
