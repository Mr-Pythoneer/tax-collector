// Hygiene (docs/parent-link-v1.md §6 "Requests", §6.3): the headers every response carries, and
// logs that never show a secret.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Relay } from "../lib/relay.mjs";
import { openRelay, call, setupChannel, newToken, channelId, fakeBox, fakeIp, rawRequest } from "./helpers.mjs";

function assertCommonHeaders(res, instance, what) {
  assert.ok(!res.error, what + ": " + res.error);
  assert.equal(res.headers.get("x-tc-instance"), instance, what);
  assert.equal(res.headers.get("x-content-type-options"), "nosniff", what);
  assert.equal(res.headers.get("referrer-policy"), "no-referrer", what);
  assert.equal(res.headers.get("x-frame-options"), "DENY", what);
}

test("every response carries X-TC-Instance, nosniff, no-referrer and DENY; every API answer also Cache-Control: no-store", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "tc-static-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, "index.html"), "<!doctype html><title>Tax Collector</title>\n");
  const r = await openRelay(t, { staticRoot: root, limits: { staticPerMinute: 5 } });
  const s = await setupChannel(r, { devices: 2 });
  const [p, q] = s.phones;
  const C = { token: s.computer.token };
  await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { ...C, body: { seq: 1, copies: { [p.id]: fakeBox() } } });
  const other = await setupChannel(r, { devices: 1 });
  const unlinked = await setupChannel(r, { devices: 1 });
  await call(r.base, "DELETE", `/v1/channels/${unlinked.ch}`, { token: unlinked.computer.token });

  const api = {};
  api["200 health"] = await call(r.base, "GET", "/v1/health");
  api["201 command"] = await call(r.base, "POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box: fakeBox() } });
  api["204 presence"] = await call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { ...C, body: { awake: true } });
  api["200 state"] = await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: p.token });
  api["304 state"] = await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: p.token, headers: { "if-none-match": api["200 state"].headers.get("etag") } });
  api["204 state"] = await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: q.token });
  api["400"] = await call(r.base, "POST", `/v1/ch/${s.ch}/presence`, { ...C, body: "not json" });
  api["401"] = await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: newToken().token });
  api["403"] = await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: other.phones[0].token });
  api["404"] = await call(r.base, "GET", "/v1/nope");
  const intruder = newToken();
  api["409"] = await call(r.base, "PUT", `/v1/channels/${s.ch}`, { token: intruder.token, body: { setupCode: r.relay.setupCode, tokenHash: intruder.hash } });
  api["410"] = await call(r.base, "GET", `/v1/ch/${unlinked.ch}/state`, { token: unlinked.phones[0].token });
  api["413"] = await rawRequest(r.base, "PUT", `/v1/ch/${s.ch}/state`, {
    headers: { authorization: "Bearer " + s.computer.token, "content-length": String(400 * 1024) },
    write: (req) => req.flushHeaders(),
  });
  const ip = fakeIp();
  for (let i = 0; i < 10; i++) await call(r.base, "GET", `/v1/pair/${channelId()}`, { ip });
  api["429"] = await call(r.base, "GET", `/v1/pair/${channelId()}`, { ip });

  for (const [what, res] of Object.entries(api)) {
    assert.equal(String(res.status), what.slice(0, 3), what);
    assertCommonHeaders(res, r.relay.instance, what);
    assert.equal(res.headers.get("cache-control"), "no-store", what);
  }

  const etag = (await call(r.base, "GET", "/")).headers.get("etag");
  const statics = {};
  statics["200 page"] = await call(r.base, "GET", "/");
  statics["304 page"] = await call(r.base, "GET", "/", { headers: { "if-none-match": etag } });
  statics["404 page"] = await call(r.base, "GET", "/nope.html");
  statics["405 page"] = await call(r.base, "POST", "/", { body: "{}" });
  const many = fakeIp();
  for (let i = 0; i < 5; i++) await call(r.base, "GET", "/", { ip: many });
  statics["429 page"] = await call(r.base, "GET", "/", { ip: many });
  for (const [what, res] of Object.entries(statics)) {
    assert.equal(String(res.status), what.slice(0, 3), what);
    assertCommonHeaders(res, r.relay.instance, what);
  }
});

test("logs never show tokens, token hashes, channel or device IDs, pairing slots, boxes or the setup code", async (t) => {
  const lines = [];
  const sink = (...args) => lines.push(args.map(String).join(" "));
  const dataDir = await mkdtemp(join(tmpdir(), "tc-relay-test-"));
  const clock = { now: 1_800_000_000_000 };
  const relay = await Relay.open({ dataDir, now: () => clock.now, log: { log: sink, warn: sink, error: sink }, logRequests: true });
  const server = relay.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    await relay.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await rm(dataDir, { recursive: true, force: true });
  });
  const r = { relay, base: `http://127.0.0.1:${server.address().port}`, clock };

  const s = await setupChannel(r, { devices: 2 });
  const [p, q] = s.phones;
  const C = { token: s.computer.token };
  const secrets = [s.computer.token, s.computer.hash, s.ch, relay.setupCode, ...[p, q].flatMap((d) => [d.token, d.hash, d.id])];
  const secret = (value) => (secrets.push(value), value);
  const slot = secret(channelId());
  const stranger = newToken();
  secret(stranger.token);
  secret(stranger.hash);

  const requests = [
    ["PUT", `/v1/ch/${s.ch}/state`, { ...C, body: { seq: 1, copies: { [p.id]: secret(fakeBox()), [q.id]: secret(fakeBox()) } } }],
    ["GET", `/v1/ch/${s.ch}/state`, { token: p.token }],
    ["POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: { box: secret(fakeBox()) } }],
    ["GET", `/v1/ch/${s.ch}/cmd?wait=0`, C],
    ["POST", `/v1/ch/${s.ch}/cmd/ack`, { ...C, body: { upTo: 1 } }],
    ["POST", `/v1/ch/${s.ch}/presence`, { ...C, body: { awake: false } }],
    ["PUT", `/v1/pair/${slot}`, { ...C, body: { ch: s.ch, hello: secret(fakeBox()) } }],
    ["GET", `/v1/pair/${slot}`, {}],
    ["POST", `/v1/pair/${slot}/toComputer`, { body: { box: secret(fakeBox()) } }],
    ["GET", `/v1/pair/${slot}/toComputer?after=0`, C],
    ["POST", `/v1/pair/${slot}/toPhone`, { ...C, body: { box: secret(fakeBox()) } }],
    ["GET", `/v1/pair/${slot}/toPhone?after=0`, {}],
    ["DELETE", `/v1/pair/${slot}`, C],
    ["GET", `/v1/ch/${s.ch}/state`, { token: stranger.token }],
    ["PUT", `/v1/channels/${s.ch}`, { token: stranger.token, body: { setupCode: relay.setupCode, tokenHash: stranger.hash } }],
    ["PUT", `/v1/channels/${secret(channelId())}`, { token: stranger.token, body: { setupCode: "WRONGCODE000", tokenHash: stranger.hash } }],
    ["GET", `/v1/pair/${secret(channelId())}`, {}],
    ["POST", `/v1/ch/${s.ch}/cmd`, { token: p.token, body: `{"box":"${secret(fakeBox())}"` }],
    ["DELETE", `/v1/channels/${s.ch}`, C],
    ["GET", `/v1/ch/${s.ch}/state`, { token: p.token }],
  ];
  const statuses = [];
  for (const [method, path, options] of requests) statuses.push((await call(r.base, method, path, options)).status);
  assert.deepEqual(statuses, [204, 200, 201, 200, 204, 204, 201, 200, 201, 200, 201, 200, 204, 401, 409, 403, 404, 400, 204, 410]);
  await relay.store.flush();

  const text = lines.join("\n");
  assert.ok(lines.some((line) => / PUT \/v1\/ch\/#[0-9a-f]{8}\/state 204 /.test(line)), "requests are logged, channels as short hashes:\n" + text);
  assert.ok(lines.length >= requests.length, "a line per request:\n" + text);
  for (const value of secrets) assert.ok(!text.includes(value), `the log shows ${value}:\n${text}`);
});
