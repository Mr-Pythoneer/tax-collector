// The parent link's cryptography: docs/parent-link-v1.md §2, §4 and §5.
// One module for the parent app (browsers) and Node 22+: it uses only WebCrypto, TextEncoder
// and CompressionStream, so the same code runs in the app, the fake clients and the tests.

const subtle = globalThis.crypto.subtle;
const te = new TextEncoder();
const td = new TextDecoder("utf-8", { fatal: true });

export const utf8 = (text) => te.encode(text);
export const fromUtf8 = (bytes) => td.decode(bytes);
export const randomBytes = (n) => globalThis.crypto.getRandomValues(new Uint8Array(n));
export const uuid = () => globalThis.crypto.randomUUID();

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) {
    out.set(p, i);
    i += p.length;
  }
  return out;
}

export function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ---- base64url without padding (RFC 4648 §5) ----

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const B64_INDEX = new Int16Array(128).fill(-1);
for (let i = 0; i < 64; i++) B64_INDEX[B64.charCodeAt(i)] = i;

export function b64(bytes) {
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64[n >> 18] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
  }
  if (bytes.length - i === 1) {
    const n = bytes[i] << 16;
    out += B64[n >> 18] + B64[(n >> 12) & 63];
  } else if (bytes.length - i === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64[n >> 18] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63];
  }
  return out;
}

/** Strict: no padding, no other characters, and unused trailing bits must be zero. */
export function unb64(text) {
  if (typeof text !== "string" || text.length % 4 === 1) throw new TypeError("Not base64url");
  const out = new Uint8Array(Math.floor((text.length * 3) / 4));
  let acc = 0;
  let bits = 0;
  let o = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    const v = c < 128 ? B64_INDEX[c] : -1;
    if (v < 0) throw new TypeError("Not base64url");
    acc = ((acc & 0xffff) << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (acc >> bits) & 0xff;
    }
  }
  if (acc & ((1 << bits) - 1)) throw new TypeError("Not base64url");
  return out;
}

// ---- Codes (§4.1, §6.2) ----

export const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** Uppercase, map O→0 and I, L→1, drop everything else that isn't in the alphabet. */
export function normaliseCode(input) {
  return [...String(input).toUpperCase()]
    .map((c) => (c === "O" ? "0" : c === "I" || c === "L" ? "1" : c))
    .filter((c) => ALPHABET.includes(c))
    .join("");
}

/** "ABCDEFGHJK" → "ABCDE-FGHJK" */
export const formatPairingCode = (code) => (code.length > 5 ? code.slice(0, 5) + "-" + code.slice(5) : code);

/** Random Crockford base32: 256 is a multiple of 32, so masking each byte has no bias. */
export const randomCode = (length) => [...randomBytes(length)].map((b) => ALPHABET[b & 31]).join("");

// ---- Primitives ----

export const sha256 = async (bytes) => new Uint8Array(await subtle.digest("SHA-256", bytes));

export async function hkdf(ikm, salt, info, length) {
  const key = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8));
}

const aesKey = (key, usages) => (key instanceof Uint8Array ? subtle.importKey("raw", key, "AES-GCM", false, usages) : key);

/** AES-256-GCM. A box is nonce(12) ‖ ciphertext ‖ tag(16). `key` is raw bytes or an AES-GCM CryptoKey. */
export async function seal(key, plaintext, aad, nonce = randomBytes(12)) {
  const k = await aesKey(key, ["encrypt"]);
  const sealed = await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, k, plaintext);
  return concat(nonce, new Uint8Array(sealed));
}

/** Throws if the box was changed, the key is wrong or the additional data differs. */
export async function open(key, box, aad) {
  if (!(box instanceof Uint8Array) || box.length < 28) throw new Error("Box too short");
  const k = await aesKey(key, ["decrypt"]);
  const iv = box.slice(0, 12);
  const opened = await subtle.decrypt({ name: "AES-GCM", iv, additionalData: aad, tagLength: 128 }, k, box.slice(12));
  return new Uint8Array(opened);
}

const EC_SIGN = { name: "ECDSA", namedCurve: "P-256" };
const EC_DH = { name: "ECDH", namedCurve: "P-256" };
const SIGNATURE = { name: "ECDSA", hash: "SHA-256" };

function checkPoint(raw) {
  if (!(raw instanceof Uint8Array) || raw.length !== 65 || raw[0] !== 4) throw new TypeError("Not a P-256 public key");
  return raw;
}

const exportRaw = async (publicKey) => new Uint8Array(await subtle.exportKey("raw", publicKey));

/** A signing key pair whose private half can't be exported. `publicRaw` is the 65-byte point. */
export async function newSigningKeys() {
  const { privateKey, publicKey } = await subtle.generateKey(EC_SIGN, false, ["sign", "verify"]);
  return { privateKey, publicRaw: await exportRaw(publicKey) };
}

/** An ECDH key pair whose private half can't be exported. */
export async function newDhKeys() {
  const { privateKey, publicKey } = await subtle.generateKey(EC_DH, false, ["deriveBits"]);
  return { privateKey, publicRaw: await exportRaw(publicKey) };
}

/** Raw r ‖ s, 64 bytes. */
export const sign = async (privateKey, bytes) => new Uint8Array(await subtle.sign(SIGNATURE, privateKey, bytes));

export async function verify(publicRaw, signature, bytes) {
  try {
    if (signature.length !== 64) return false;
    const key = await subtle.importKey("raw", checkPoint(publicRaw), EC_SIGN, false, ["verify"]);
    return await subtle.verify(SIGNATURE, key, signature, bytes);
  } catch {
    return false;
  }
}

/** The shared secret: the raw 32-byte X coordinate. */
export async function ecdh(privateKey, publicRaw) {
  const pub = await subtle.importKey("raw", checkPoint(publicRaw), EC_DH, false, []);
  return new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: pub }, privateKey, 256));
}

// ---- Labels ----

export const pairAad = (slot) => utf8("tc v1 pair|" + slot);
export const commandAad = (channel, deviceId) => utf8("tc v1 cmd|" + channel + "|" + deviceId);
export const stateAad = (channel, deviceId) => utf8("tc v1 state|" + channel + "|" + deviceId);

// ---- Pairing (§4) ----

/** The slot, key and additional data for a pairing code, typed any way the parent likes. */
export async function pairingSecrets(code) {
  const normalised = normaliseCode(code);
  if (normalised.length !== 10) throw new RangeError("A pairing code has 10 characters");
  const ikm = utf8(normalised);
  const salt = utf8("tc v1 pair");
  const slot = b64(await hkdf(ikm, salt, utf8("tc v1 pair slot"), 16));
  const pairKey = await hkdf(ikm, salt, utf8("tc v1 pair key"), 32);
  return { code: normalised, slot, pairKey };
}

/** A pairing message: JSON with a "t" field, sealed with the pairing key. Returns base64url. */
export const sealPairing = async (pairKey, slot, message, nonce) =>
  b64(await seal(pairKey, utf8(JSON.stringify(message)), pairAad(slot), nonce));

/** Opens and parses a pairing message. Throws if it doesn't open or isn't a JSON object with a "t". */
export async function openPairing(pairKey, slot, box) {
  const message = JSON.parse(fromUtf8(await open(pairKey, unb64(box), pairAad(slot))));
  if (!message || typeof message !== "object" || typeof message.t !== "string") throw new Error("Not a pairing message");
  return message;
}

export async function commitment({ signPub, dhPub, nonce, tokenHash, name }) {
  return b64(await sha256(concat(utf8("tc v1 commit"), checkPoint(signPub), checkPoint(dhPub), nonce, tokenHash, utf8(name))));
}

/** The 6-digit comparison code both screens show, as "123456". */
export async function comparisonCode({ computerNonce, phoneNonce, computerDhPub, phoneSignPub, phoneDhPub }) {
  const h = await sha256(concat(utf8("tc v1 sas"), computerNonce, phoneNonce, computerDhPub, phoneSignPub, phoneDhPub));
  const n = new DataView(h.buffer, h.byteOffset, 4).getUint32(0, false);
  return String(n % 1_000_000).padStart(6, "0");
}

/** "123456" → "123 456" */
export const formatComparisonCode = (code) => code.slice(0, 3) + " " + code.slice(3);

/**
 * The link key (§4.4). By default a non-extractable AES-GCM CryptoKey, as the parent app keeps it;
 * `{ raw: true }` returns the 32 bytes instead, for the computer's side.
 */
export async function deriveLinkKey(shared, channel, deviceId, { raw = false, extractable = false } = {}) {
  const base = await subtle.importKey("raw", shared, "HKDF", false, ["deriveBits", "deriveKey"]);
  const params = { name: "HKDF", hash: "SHA-256", salt: unb64(channel), info: utf8("tc v1 link|" + deviceId) };
  if (raw) return new Uint8Array(await subtle.deriveBits(params, base, 256));
  return subtle.deriveKey(params, base, { name: "AES-GCM", length: 256 }, extractable, ["encrypt", "decrypt"]);
}

// ---- Commands (§5.1) ----

/** The exact JSON text that gets signed, with the fields in the spec's order. */
export const commandBody = ({ channel, deviceId, n, at, id, type, args }) =>
  JSON.stringify({ v: 1, ch: channel, dev: deviceId, n, at, id, type, args });

/** Signs the body bytes, then seals sig(64) ‖ body. Returns the box as base64url. */
export async function sealCommand({ linkKey, signKey, channel, deviceId, body, nonce }) {
  const bodyBytes = utf8(body);
  const signature = await sign(signKey, bodyBytes);
  return b64(await seal(linkKey, concat(signature, bodyBytes), commandAad(channel, deviceId), nonce));
}

/**
 * The computer's first three steps for one command (§5.1): open the box, then check the
 * signature over the body bytes as received, before parsing them. The caller checks the rest.
 * Returns { ok: true, body, command } or { ok: false, reason }.
 */
export async function openCommand({ linkKey, signPub, channel, deviceId, box }) {
  let opened;
  try {
    opened = await open(linkKey, unb64(box), commandAad(channel, deviceId));
  } catch {
    return { ok: false, reason: "bad_box" };
  }
  if (opened.length <= 64) return { ok: false, reason: "bad_box" };
  const signature = opened.slice(0, 64);
  const bodyBytes = opened.slice(64);
  if (!(await verify(signPub, signature, bodyBytes))) return { ok: false, reason: "bad_signature" };
  let body, command;
  try {
    body = fromUtf8(bodyBytes);
    command = JSON.parse(body);
  } catch {
    return { ok: false, reason: "bad_args" };
  }
  if (!command || typeof command !== "object" || Array.isArray(command)) return { ok: false, reason: "bad_args" };
  return { ok: true, body, command };
}

// ---- State (§5.2) ----

async function pipe(bytes, transform, maxBytes) {
  const source = new ReadableStream({
    start(controller) {
      controller.enqueue(bytes);
      controller.close();
    },
  });
  const reader = source.pipeThrough(transform).getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maxBytes) {
      await reader.cancel();
      throw new RangeError("Too large once inflated");
    }
    chunks.push(value);
  }
  return concat(...chunks);
}

/** Raw DEFLATE, no zlib header (RFC 1951). */
export const deflateRaw = (bytes) => pipe(bytes, new CompressionStream("deflate-raw"), Infinity);
/** Stops at `maxBytes` of output, so a small box can't inflate into something huge. */
export const inflateRaw = (bytes, maxBytes = 16 * 1024 * 1024) => pipe(bytes, new DecompressionStream("deflate-raw"), maxBytes);

/** Compresses the JSON text and seals one device's copy. Returns base64url. */
export async function sealState({ linkKey, channel, deviceId, json, nonce }) {
  return b64(await seal(linkKey, await deflateRaw(utf8(json)), stateAad(channel, deviceId), nonce));
}

/** Opens, inflates and parses one device's copy. Throws if anything is off. */
export async function openState({ linkKey, channel, deviceId, box, maxBytes }) {
  const opened = await open(linkKey, unb64(box), stateAad(channel, deviceId));
  return JSON.parse(fromUtf8(await inflateRaw(opened, maxBytes)));
}
