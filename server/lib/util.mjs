// Small helpers for the relay: strict base64url, hashes, ID checks, codes.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

const B64URL = /^[A-Za-z0-9_-]*$/;

/** Strict base64url without padding: returns a Buffer, or null if `text` isn't canonical base64url. */
export function unb64(text) {
  if (typeof text !== "string" || !B64URL.test(text) || text.length % 4 === 1) return null;
  const bytes = Buffer.from(text, "base64url");
  return bytes.toString("base64url") === text ? bytes : null;
}

export const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
export const sha256 = (bytes) => createHash("sha256").update(bytes).digest();
/** Channel IDs appear in logs and file names only as hashes. */
export const shortHash = (text) => sha256(text).toString("hex").slice(0, 8);
export const fileKey = (text) => sha256("tc v1 file|" + text).toString("hex").slice(0, 32);
export const randomId = (n = 16) => b64(randomBytes(n));

/** Compares two equal-purpose secrets without leaking where they differ. */
export function sameSecret(a, b) {
  const x = sha256(String(a));
  const y = sha256(String(b));
  return timingSafeEqual(x, y);
}

/** 16 random bytes in base64url: channel IDs and pairing slots. */
export const isId16 = (text) => typeof text === "string" && text.length === 22 && unb64(text)?.length === 16;
/** SHA-256 digests in base64url: token hashes. */
export const isHash = (text) => typeof text === "string" && text.length === 43 && unb64(text)?.length === 32;
export const isDeviceId = (text) =>
  typeof text === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text);
export const isCount = (v) => Number.isSafeInteger(v) && v >= 0;

/** A sealed box: nonce(12) ‖ ciphertext ‖ tag(16), so at least 28 bytes. Returns its size, or -1. */
export function boxSize(text, max) {
  if (typeof text !== "string" || text.length > Math.ceil((max * 4) / 3) + 4) return -1;
  const bytes = unb64(text);
  if (!bytes || bytes.length < 28 || bytes.length > max) return -1;
  return bytes.length;
}

/** Throws 400 if `text` isn't a box, or 413 if it's a box larger than `max` bytes. */
export function checkBox(text, max, what) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text) || text.length % 4 === 1) throw new HttpError(400, `${what} must be a sealed box (base64url)`);
  if (text.length > Math.ceil((max * 4) / 3) + 4) throw new HttpError(413, `${what} must be at most ${Math.round(max / 1024)} KB`);
  const bytes = unb64(text);
  if (!bytes || bytes.length < 28) throw new HttpError(400, `${what} must be a sealed box (base64url)`);
  if (bytes.length > max) throw new HttpError(413, `${what} must be at most ${Math.round(max / 1024)} KB`);
  return bytes.length;
}

export const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function normaliseCode(input) {
  return [...String(input).toUpperCase()]
    .map((c) => (c === "O" ? "0" : c === "I" || c === "L" ? "1" : c))
    .filter((c) => ALPHABET.includes(c))
    .join("");
}

export const randomCode = (length) => [...randomBytes(length)].map((b) => ALPHABET[b & 31]).join("");

/** "ABCDEFGHJKMN" → "ABCD-EFGH-JKMN" */
export const formatSetupCode = (code) => code.match(/.{1,4}/g).join("-");

/** An error that becomes an HTTP answer: {"error": code, "message": …}. */
export class HttpError extends Error {
  constructor(status, message, extra, headers) {
    super(message);
    this.status = status;
    this.extra = extra;
    this.headers = headers;
  }
}

export const ERROR_CODES = {
  400: "bad_request",
  401: "unauthorized",
  403: "forbidden",
  404: "not_found",
  405: "bad_request",
  409: "conflict",
  410: "gone",
  413: "too_large",
  429: "rate_limited",
  500: "server_error",
  503: "unavailable",
};
