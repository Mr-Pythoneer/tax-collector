// Makes spec/vectors/v1.json: fixed inputs and the exact outputs every implementation of
// docs/parent-link-v1.md must reproduce or accept. Run with Node 22+:  node spec/vectors/gen.mjs
// Re-running changes only the ECDSA signature (signing is randomised); everything else is fixed.
import { writeFileSync } from "node:fs";
import { deflateRawSync, inflateRawSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const subtle = globalThis.crypto.subtle;
const te = new TextEncoder();
const td = new TextDecoder();

export const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
export const unb64 = (s) => new Uint8Array(Buffer.from(s, "base64url"));
const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
};
const ascii = (s) => te.encode(s);
const range = (start, n) => Uint8Array.from({ length: n }, (_, i) => (start + i) & 0xff);
const sha256 = async (bytes) => new Uint8Array(await subtle.digest("SHA-256", bytes));

export const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export function normaliseCode(input) {
  return [...input.toUpperCase()]
    .map((c) => (c === "O" ? "0" : c === "I" || c === "L" ? "1" : c))
    .filter((c) => ALPHABET.includes(c))
    .join("");
}

export async function hkdf(ikm, salt, info, length) {
  const key = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8));
}

export async function seal(keyBytes, nonce, plaintext, aad) {
  const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, key, plaintext));
  return cat(nonce, ct);
}

export async function open(keyBytes, box, aad) {
  const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: box.slice(0, 12), additionalData: aad }, key, box.slice(12)));
}

// Fixed test keys (P-256), as JWK parts. Never use these for anything real.
const KEYS = {
  phoneSign: { d: "hrPH4leN3gZPbiSu5dCrKAcS9jpKVjKSwjC4wEv2csk", x: "01WexG_PJJJPPCETNivQt5yShfVUbguWpQDD_gGh1n8", y: "BJA-ylRVazOvL8nmBSUGk_wZ-THcTdJsU6QimQDhnso" },
  phoneDh: { d: "mwh0NRkKmbMbRrBDMFASuATFcBe1fSD0RixmY9jTHjg", x: "xM8Sjb5tDaJ3d1b2SBNfd_Z2mfqh_-onBcDjGqC2LnE", y: "bJmUnkiKdU85ryHbPfMlNWfvv0tYb2IK-Up7xj-vGOc" },
  computerDh: { d: "VxYz3JpOJFGAQDTWgUrMZzZAwooGuGUiVQzbH72ZlDI", x: "LRqEizaiJ2jCvA2_RkZ39GeGi2Gr4WC0WQTHQwDFKlQ", y: "I--cS4qIDVPgxs_8lxqMV2VunV0b3aok94F4iX_pZRE" },
};
const jwk = (k, priv) => ({ kty: "EC", crv: "P-256", x: k.x, y: k.y, ...(priv ? { d: k.d } : {}), ext: true });
export const rawPublic = (k) => cat(Uint8Array.of(4), unb64(k.x), unb64(k.y));

async function main() {
  // §4.1 Pairing code
  const codeInput = "7kq2m-9xwhr";
  const code = normaliseCode(codeInput);
  const ikm = te.encode(code);
  const slot = b64(await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair slot"), 16));
  const pairKey = await hkdf(ikm, ascii("tc v1 pair"), ascii("tc v1 pair key"), 32);
  const pairAad = ascii("tc v1 pair|" + slot);

  const channel = b64(range(0x10, 16));
  const computerDhPub = rawPublic(KEYS.computerDh);
  const helloJson = JSON.stringify({ t: "hello", v: 1, ch: channel, name: "Test Mac", platform: "mac", dhKey: b64(computerDhPub) });
  const helloNonce = range(0xa0, 12);
  const helloBox = await seal(pairKey, helloNonce, te.encode(helloJson), pairAad);

  // §4.2 Commit, nonces, reveal, code
  const phoneSignPub = rawPublic(KEYS.phoneSign);
  const phoneDhPub = rawPublic(KEYS.phoneDh);
  const phoneNonce = range(0x20, 32);
  const computerNonce = range(0x40, 32);
  const deviceToken = range(0x60, 32);
  const tokenHash = await sha256(deviceToken);
  const deviceName = "Mom's iPhone";
  const commit = b64(await sha256(cat(ascii("tc v1 commit"), phoneSignPub, phoneDhPub, phoneNonce, tokenHash, te.encode(deviceName))));
  const h = await sha256(cat(ascii("tc v1 sas"), computerNonce, phoneNonce, computerDhPub, phoneSignPub, phoneDhPub));
  const sas = String(new DataView(h.buffer).getUint32(0, false) % 1_000_000).padStart(6, "0");

  // §4.4 Link key, worked out from both ends
  const ecdh = async (privKey, pubKey) => {
    const priv = await subtle.importKey("jwk", jwk(privKey, true), { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
    const pub = await subtle.importKey("raw", rawPublic(pubKey), { name: "ECDH", namedCurve: "P-256" }, false, []);
    return new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: pub }, priv, 256));
  };
  const shared = await ecdh(KEYS.computerDh, KEYS.phoneDh);
  const sharedFromPhone = await ecdh(KEYS.phoneDh, KEYS.computerDh);
  if (b64(shared) !== b64(sharedFromPhone)) throw new Error("ECDH sides disagree");
  const deviceId = "6f1c0e3a-2b4d-4c8e-9a1f-0d2e3c4b5a69";
  const linkKey = await hkdf(shared, unb64(channel), ascii("tc v1 link|" + deviceId), 32);

  // §5.1 A command
  const body = JSON.stringify({
    v: 1, ch: channel, dev: deviceId, n: 1729200000123, at: 1729200000123,
    id: "0b8f2c64-7d1e-4f3a-9c5b-2e6d8a4f1b37", type: "lock", args: { until: 1729210000000, strength: "homework" },
  });
  const signKey = await subtle.importKey("jwk", jwk(KEYS.phoneSign, true), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signKey, te.encode(body)));
  const tampered = signature.slice();
  tampered[10] ^= 0x01;
  const cmdAad = ascii("tc v1 cmd|" + channel + "|" + deviceId);
  const cmdNonce = range(0xb0, 12);
  const cmdBox = await seal(linkKey, cmdNonce, cat(signature, te.encode(body)), cmdAad);

  // §5.2 A state copy
  const stateJson = JSON.stringify({
    v: 1, seq: 1, sentAt: 1729200000000,
    computer: { name: "Test Mac", platform: "mac", app: "0.7.0", os: "macOS", timeZone: "UTC", capabilities: ["lock"] },
    access: { mode: "normal", until: null, strength: null, by: "", at: 0 },
    lock: { locked: false, reasons: [] }, tasks: [], repeats: [],
    apps: { builtIn: [], allowed: [], blocked: [], running: [], recent: [] },
    settings: { penaltyMinutes: 30, extensionsEnabled: true },
    trackRecord: { onTime: 0, late: 0, missed: 0, extensionsThisWeek: 0 },
    activity: [], results: [], devices: [], flags: [], message: null,
  });
  const deflated = deflateRawSync(te.encode(stateJson));
  const stateAad = ascii("tc v1 state|" + channel + "|" + deviceId);
  const stateNonce = range(0xc0, 12);
  const stateBox = await seal(linkKey, stateNonce, deflated, stateAad);

  // Check our own work before writing it down.
  if (td.decode(await open(pairKey, helloBox, pairAad)) !== helloJson) throw new Error("hello round trip");
  const opened = await open(linkKey, cmdBox, cmdAad);
  const verifyKey = await subtle.importKey("raw", phoneSignPub, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  if (!(await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifyKey, opened.slice(0, 64), opened.slice(64)))) throw new Error("signature");
  if (await subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifyKey, tampered, te.encode(body))) throw new Error("tampered verified");
  if (td.decode(inflateRawSync(await open(linkKey, stateBox, stateAad))) !== stateJson) throw new Error("state round trip");

  const vectors = {
    v: 1,
    note: "Test vectors for docs/parent-link-v1.md. The keys here are public test keys: never use them for anything real. Byte strings are base64url without padding; text is UTF-8.",
    normalise: [
      [codeInput, code],
      ["abc def ghjk", "ABCDEFGHJK"],
      ["o0-Il1 lO", "0011110"],
      ["ABCDEFGHJKU", "ABCDEFGHJK"],
    ],
    pairing: {
      code: codeInput, normalised: code, slot, pairKey: b64(pairKey), aad: "tc v1 pair|" + slot,
      hello: { plaintext: helloJson, nonce: b64(helloNonce), box: b64(helloBox) },
      phone: {
        signKey: { ...KEYS.phoneSign, public: b64(phoneSignPub) },
        dhKey: { ...KEYS.phoneDh, public: b64(phoneDhPub) },
        nonce: b64(phoneNonce), token: b64(deviceToken), tokenHash: b64(tokenHash), name: deviceName,
      },
      computer: { dhKey: { ...KEYS.computerDh, public: b64(computerDhPub) }, nonce: b64(computerNonce) },
      commit,
      sas,
    },
    link: { channel, deviceId, shared: b64(shared), linkKey: b64(linkKey) },
    command: {
      body, signature: b64(signature), tamperedSignature: b64(tampered),
      aad: "tc v1 cmd|" + channel + "|" + deviceId, nonce: b64(cmdNonce), box: b64(cmdBox),
    },
    state: {
      json: stateJson, deflated: b64(deflated),
      aad: "tc v1 state|" + channel + "|" + deviceId, nonce: b64(stateNonce), box: b64(stateBox),
    },
  };
  const out = join(dirname(fileURLToPath(import.meta.url)), "v1.json");
  writeFileSync(out, JSON.stringify(vectors, null, 2) + "\n");
  console.log("Wrote " + out + " (code " + sas + ")");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
