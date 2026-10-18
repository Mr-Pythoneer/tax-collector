// The parent app's files (docs/parent-link-v1.md §6.3): served from a fixed list, read once at
// startup, never from a path built from the URL, and with the CSP the spec gives.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { openRelay, call, fakeIp, rawRequest } from "./helpers.mjs";

/** Copied from §6.3 on purpose, rather than imported from the server. */
const SPEC_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
  "frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

const DECOY = "DECOY: a file outside the list of parent-app files";
const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a4f20000000049454e44ae426082", "hex");

/**
 * A folder like the repository: parent/ with a few of the listed files (and some that aren't
 * listed), next to a server/ folder that must never be reachable.
 */
async function parentFolder(t) {
  const top = await mkdtemp(join(tmpdir(), "tc-static-test-"));
  t.after(() => rm(top, { recursive: true, force: true }));
  const root = join(top, "parent");
  const listed = {
    "index.html": "<!doctype html><title>Tax Collector</title>\n",
    "app.css": "body { margin: 0 }\n",
    "js/app.js": "export const app = 1;\n",
    "icons/icon-192.png": PNG,
  };
  const unlisted = ["secret.txt", "index.htm", "js/secret.js", "server/server.mjs", "data/server.json", ".env"];
  const write = async (file, body) => {
    await mkdir(dirname(join(top, file)), { recursive: true });
    await writeFile(join(top, file), body);
  };
  for (const [file, body] of Object.entries(listed)) await write("parent/" + file, body);
  for (const file of unlisted) await write("parent/" + file, DECOY);
  await write("server/server.mjs", DECOY);
  await write("server/data/server.json", DECOY);
  await write("secret.txt", DECOY);
  return { root, top, listed };
}

test("listed files are served with their type, Cache-Control no-cache, an ETag and exactly the CSP of §6.3", async (t) => {
  const { root, listed } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root });
  const cases = [
    ["/", "index.html", "text/html; charset=utf-8"],
    ["/app.css", "app.css", "text/css; charset=utf-8"],
    ["/js/app.js", "js/app.js", "text/javascript; charset=utf-8"],
    ["/icons/icon-192.png", "icons/icon-192.png", "image/png"],
  ];
  const etags = new Set();
  for (const [path, file, type] of cases) {
    const res = await rawRequest(r.base, "GET", path);
    assert.equal(res.status, 200, path);
    assert.deepEqual(res.body, Buffer.from(listed[file]), path);
    assert.equal(res.headers.get("content-type"), type, path);
    assert.equal(res.headers.get("content-length"), String(res.body.length), path);
    assert.equal(res.headers.get("cache-control"), "no-cache", path);
    assert.equal(res.headers.get("content-security-policy"), SPEC_CSP, path);
    assert.match(res.headers.get("etag"), /^"[^"]+"$/, path);
    etags.add(res.headers.get("etag"));
  }
  assert.equal(etags.size, cases.length, "each file has its own ETag");
});

test("If-None-Match with a file's ETag → 304; HEAD gives the headers alone; other methods → 405", async (t) => {
  const { root, listed } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root });
  const first = await call(r.base, "GET", "/app.css");
  const etag = first.headers.get("etag");
  for (const value of [etag, `W/${etag}`, `"other", ${etag}`, "*"]) {
    const res = await call(r.base, "GET", "/app.css", { headers: { "if-none-match": value } });
    assert.equal(res.status, 304, value);
    assert.equal(res.text, "");
    assert.equal(res.headers.get("etag"), etag);
    assert.equal(res.headers.get("content-security-policy"), SPEC_CSP);
  }
  assert.equal((await call(r.base, "GET", "/app.css", { headers: { "if-none-match": '"other"' } })).text, listed["app.css"]);
  assert.equal((await call(r.base, "GET", "/", { headers: { "if-none-match": etag } })).status, 200, "another file's ETag doesn't match");

  const head = await rawRequest(r.base, "HEAD", "/app.css");
  assert.equal(head.status, 200);
  assert.equal(head.body.length, 0);
  assert.equal(head.headers.get("content-length"), String(Buffer.byteLength(listed["app.css"])));
  assert.equal(head.headers.get("etag"), etag);

  for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
    const res = await call(r.base, method, "/app.css", { body: "{}" });
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get("allow"), "GET, HEAD");
  }
});

test("only files in the table are served, even if others sit in the folder; listed files that are missing → 404", async (t) => {
  const { root } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root });
  for (const path of ["/index.html", "/index.htm", "/secret.txt", "/js/secret.js", "/server/server.mjs", "/data/server.json", "/.env", "/js/", "/icons/", "/JS/APP.JS", "/app.css/", "/sw.js", "/js/ui.js", "/manifest.webmanifest"]) {
    const res = await rawRequest(r.base, "GET", path);
    assert.equal(res.status, 404, path);
    assert.ok(!res.text.includes("DECOY"), path);
    assert.equal(res.headers.get("cache-control"), "no-store", path);
  }
});

test("path traversal never reaches a file outside the table", async (t) => {
  const { root, listed } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root });
  const servable = new Set(Object.values(listed).map((body) => Buffer.from(body).toString("base64")));
  const attempts = [
    "/../server/server.mjs",
    "/js/../../server/server.mjs",
    "/%2e%2e/server/server.mjs",
    "/%2E%2E/%2e%2e/server/server.mjs",
    "/server/server.mjs",
    "/js/app.js?x=../../",
    "/js/..%2f..%2fserver/server.mjs",
    "/js/%2e%2e%2f%2e%2e%2fserver/server.mjs",
    "/..\\server\\server.mjs",
    "/js\\..\\..\\server\\server.mjs",
    "/....//server/server.mjs",
    "//server/server.mjs",
    "/../secret.txt",
    "/%2e%2e/secret.txt",
    "/js/app.js%00../../secret.txt",
    "/../../../../../../etc/passwd",
    "http://relay.example/../server/server.mjs",
  ];
  for (const path of attempts) {
    const res = await rawRequest(r.base, "GET", path);
    assert.ok(!res.error, path + ": " + res.error);
    assert.ok(!res.text.includes("DECOY"), path + " served a file outside the table");
    assert.ok(res.status === 404 || (res.status === 200 && servable.has(res.body.toString("base64"))), `${path}: ${res.status}`);
  }
  for (const path of attempts.slice(0, 5)) assert.equal((await rawRequest(r.base, "GET", path)).status, 404, path);
  const withQuery = await rawRequest(r.base, "GET", "/js/app.js?x=../../");
  assert.equal(withQuery.status, 200);
  assert.equal(withQuery.text, listed["js/app.js"], "the query is ignored; the path is a listed file");
});

test("files are read into memory once, at startup", async (t) => {
  const { root, listed } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root });
  await writeFile(join(root, "app.css"), "body { color: red }\n");
  await rm(join(root, "js/app.js"));
  await writeFile(join(root, "sw.js"), "// added after startup\n");
  assert.equal((await call(r.base, "GET", "/app.css")).text, listed["app.css"]);
  assert.equal((await call(r.base, "GET", "/js/app.js")).text, listed["js/app.js"]);
  assert.equal((await call(r.base, "GET", "/sw.js")).status, 404);
});

test("a relay started without a staticRoot serves no files", async (t) => {
  const r = await openRelay(t);
  assert.equal((await call(r.base, "GET", "/")).status, 404);
  assert.equal((await call(r.base, "GET", "/app.css")).status, 404);
});

test("with the real parent/ folder, nothing outside the table is served either", async (t) => {
  const parent = fileURLToPath(new URL("../../parent/", import.meta.url));
  const r = await openRelay(t, { staticRoot: parent });
  for (const path of ["/README.md", "/js/", "/../server/server.mjs", "/%2e%2e/server/lib/relay.mjs", "/../docs/parent-link-v1.md"]) {
    const res = await rawRequest(r.base, "GET", path);
    assert.equal(res.status, 404, path);
    assert.equal(res.text, "Not found\n", path);
  }
});

test("static requests are limited per address (staticPerMinute)", async (t) => {
  const { root } = await parentFolder(t);
  const r = await openRelay(t, { staticRoot: root, limits: { staticPerMinute: 3 } });
  const ip = fakeIp();
  for (let i = 0; i < 3; i++) assert.equal((await call(r.base, "GET", "/", { ip })).status, 200);
  const limited = await call(r.base, "GET", "/app.css", { ip });
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "20");
  assert.equal(limited.headers.get("content-type"), "text/plain; charset=utf-8");
  assert.equal((await call(r.base, "GET", "/", { ip: fakeIp() })).status, 200, "another address");
  assert.equal((await call(r.base, "GET", "/v1/health", { ip })).status, 200, "the API has its own limits");
});
