// parent/js/linkcrypto.js against spec/vectors/v1.json: the parent app's crypto must agree
// byte for byte with every other implementation of docs/parent-link-v1.md.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as lc from "../../parent/js/linkcrypto.js";

const V = JSON.parse(readFileSync(fileURLToPath(new URL("../../spec/vectors/v1.json", import.meta.url)), "utf8"));
const { b64, unb64, utf8, fromUtf8 } = lc;
const subtle = globalThis.crypto.subtle;

// The vectors' fixed keys, imported the way a test can (the app makes its own, non-extractable).
const importPrivate = (k, alg, usages) =>
  subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: k.x, y: k.y, d: k.d }, { name: alg, namedCurve: "P-256" }, false, usages);

test("base64url round trips and is strict", () => {
  for (let n = 0; n < 70; n++) {
    const bytes = lc.randomBytes(n);
    const text = b64(bytes);
    assert.equal(text, Buffer.from(bytes).toString("base64url"));
    assert.deepEqual(unb64(text), bytes);
  }
  for (const bad of ["a", "ab=", "ab+c", "ab/c", "abc!", "AB", "AAB", " AAAA"]) {
    assert.throws(() => unb64(bad), TypeError, bad);
  }
  assert.deepEqual(unb64(""), new Uint8Array(0));
});

test("pairing codes normalise", () => {
  for (const [input, want] of V.normalise) assert.equal(lc.normaliseCode(input), want);
  assert.equal(lc.formatPairingCode("ABCDEFGHJK"), "ABCDE-FGHJK");
  const code = lc.randomCode(12);
  assert.equal(code.length, 12);
  assert.equal(lc.normaliseCode(code), code);
});

test("slot and pairing key come from the code", async () => {
  const p = V.pairing;
  const s = await lc.pairingSecrets(p.code);
  assert.equal(s.code, p.normalised);
  assert.equal(s.slot, p.slot);
  assert.equal(b64(s.pairKey), p.pairKey);
  assert.equal(fromUtf8(lc.pairAad(s.slot)), p.aad);
  await assert.rejects(lc.pairingSecrets("ABCDE"), RangeError);
});

test("hello box seals and opens exactly", async () => {
  const p = V.pairing;
  const box = await lc.sealPairing(unb64(p.pairKey), p.slot, JSON.parse(p.hello.plaintext), unb64(p.hello.nonce));
  assert.equal(box, p.hello.box);
  const hello = await lc.openPairing(unb64(p.pairKey), p.slot, p.hello.box);
  assert.deepEqual(hello, JSON.parse(p.hello.plaintext));
  await assert.rejects(lc.openPairing(unb64(p.pairKey), "x" + p.slot.slice(1), p.hello.box));
  const flipped = unb64(p.hello.box);
  flipped[20] ^= 1;
  await assert.rejects(lc.openPairing(unb64(p.pairKey), p.slot, b64(flipped)));
});

test("commitment and comparison code", async () => {
  const p = V.pairing;
  assert.equal(b64(await lc.sha256(unb64(p.phone.token))), p.phone.tokenHash);
  const commit = await lc.commitment({
    signPub: unb64(p.phone.signKey.public), dhPub: unb64(p.phone.dhKey.public),
    nonce: unb64(p.phone.nonce), tokenHash: unb64(p.phone.tokenHash), name: p.phone.name,
  });
  assert.equal(commit, p.commit);
  const sas = await lc.comparisonCode({
    computerNonce: unb64(p.computer.nonce), phoneNonce: unb64(p.phone.nonce),
    computerDhPub: unb64(p.computer.dhKey.public), phoneSignPub: unb64(p.phone.signKey.public),
    phoneDhPub: unb64(p.phone.dhKey.public),
  });
  assert.equal(sas, p.sas);
  assert.equal(lc.formatComparisonCode(sas), sas.slice(0, 3) + " " + sas.slice(3));
});

test("link key from either end, raw and as a non-extractable key", async () => {
  const p = V.pairing, L = V.link;
  const computerPriv = await importPrivate(p.computer.dhKey, "ECDH", ["deriveBits"]);
  const phonePriv = await importPrivate(p.phone.dhKey, "ECDH", ["deriveBits"]);
  const a = await lc.ecdh(computerPriv, unb64(p.phone.dhKey.public));
  const b = await lc.ecdh(phonePriv, unb64(p.computer.dhKey.public));
  assert.equal(b64(a), L.shared);
  assert.equal(b64(b), L.shared);
  assert.equal(b64(await lc.deriveLinkKey(a, L.channel, L.deviceId, { raw: true })), L.linkKey);

  const exportable = await lc.deriveLinkKey(b, L.channel, L.deviceId, { extractable: true });
  assert.equal(b64(new Uint8Array(await subtle.exportKey("raw", exportable))), L.linkKey);
  const kept = await lc.deriveLinkKey(b, L.channel, L.deviceId);
  assert.equal(kept.extractable, false);
  await assert.rejects(subtle.exportKey("raw", kept));
  // The kept key opens what the raw key sealed.
  const opened = await lc.open(kept, unb64(V.command.box), utf8(V.command.aad));
  assert.equal(fromUtf8(opened.slice(64)), V.command.body);
});

test("command opens, and only the true signature verifies", async () => {
  const C = V.command, L = V.link, p = V.pairing;
  const signPub = unb64(p.phone.signKey.public);
  const res = await lc.openCommand({ linkKey: unb64(L.linkKey), signPub, channel: L.channel, deviceId: L.deviceId, box: C.box });
  assert.equal(res.ok, true);
  assert.equal(res.body, C.body);
  assert.equal(res.command.type, "lock");
  assert.equal(fromUtf8(lc.commandAad(L.channel, L.deviceId)), C.aad);

  assert.ok(await lc.verify(signPub, unb64(C.signature), utf8(C.body)));
  assert.ok(!(await lc.verify(signPub, unb64(C.tamperedSignature), utf8(C.body))));
  assert.ok(!(await lc.verify(signPub, unb64(C.signature), utf8(C.body.replace("homework", "all")))));

  // Re-seal with the tampered signature: the box opens but the signature fails.
  const tampered = await lc.seal(unb64(L.linkKey), lc.concat(unb64(C.tamperedSignature), utf8(C.body)), utf8(C.aad));
  const bad = await lc.openCommand({ linkKey: unb64(L.linkKey), signPub, channel: L.channel, deviceId: L.deviceId, box: b64(tampered) });
  assert.deepEqual(bad, { ok: false, reason: "bad_signature" });
  // Another device's additional data doesn't open it.
  const wrong = await lc.openCommand({ linkKey: unb64(L.linkKey), signPub, channel: L.channel, deviceId: "x", box: C.box });
  assert.deepEqual(wrong, { ok: false, reason: "bad_box" });
});

test("a command the app signs is the spec's bytes and verifies", async () => {
  const L = V.link, p = V.pairing;
  const fields = JSON.parse(V.command.body);
  const body = lc.commandBody({ channel: fields.ch, deviceId: fields.dev, n: fields.n, at: fields.at, id: fields.id, type: fields.type, args: fields.args });
  assert.equal(body, V.command.body);
  const signKey = await importPrivate(p.phone.signKey, "ECDSA", ["sign"]);
  const linkKey = await lc.deriveLinkKey(unb64(L.shared), L.channel, L.deviceId);
  const box = await lc.sealCommand({ linkKey, signKey, channel: L.channel, deviceId: L.deviceId, body, nonce: unb64(V.command.nonce) });
  const res = await lc.openCommand({ linkKey: unb64(L.linkKey), signPub: unb64(p.phone.signKey.public), channel: L.channel, deviceId: L.deviceId, box });
  assert.equal(res.ok, true);
  assert.equal(res.body, V.command.body);
});

test("state opens and inflates, and the app's own compression round trips", async () => {
  const S = V.state, L = V.link;
  const opened = await lc.open(unb64(L.linkKey), unb64(S.box), utf8(S.aad));
  assert.equal(b64(opened), S.deflated);
  assert.equal(fromUtf8(await lc.inflateRaw(opened)), S.json);
  const state = await lc.openState({ linkKey: unb64(L.linkKey), channel: L.channel, deviceId: L.deviceId, box: S.box });
  assert.deepEqual(state, JSON.parse(S.json));
  await assert.rejects(lc.openState({ linkKey: unb64(L.linkKey), channel: "other", deviceId: L.deviceId, box: S.box }));

  const box = await lc.sealState({ linkKey: unb64(L.linkKey), channel: L.channel, deviceId: L.deviceId, json: S.json });
  const back = await lc.openState({ linkKey: await lc.deriveLinkKey(unb64(L.shared), L.channel, L.deviceId), channel: L.channel, deviceId: L.deviceId, box });
  assert.deepEqual(back, JSON.parse(S.json));
});

test("inflating stops at the size limit", async () => {
  const big = await lc.deflateRaw(new Uint8Array(4 * 1024 * 1024));
  assert.ok(big.length < 10_000);
  await assert.rejects(lc.inflateRaw(big, 1024 * 1024), RangeError);
  assert.equal((await lc.inflateRaw(big, 8 * 1024 * 1024)).length, 4 * 1024 * 1024);
});

test("generated keys keep their private half inside", async () => {
  const s = await lc.newSigningKeys();
  const d = await lc.newDhKeys();
  assert.equal(s.privateKey.extractable, false);
  assert.equal(d.privateKey.extractable, false);
  assert.equal(s.publicRaw.length, 65);
  assert.equal(d.publicRaw[0], 4);
  await assert.rejects(subtle.exportKey("jwk", s.privateKey));
  const msg = utf8("hello");
  assert.ok(await lc.verify(s.publicRaw, await lc.sign(s.privateKey, msg), msg));
  assert.equal(await lc.verify(new Uint8Array(65), new Uint8Array(64), msg), false);
});
