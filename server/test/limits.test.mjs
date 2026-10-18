// Per-address rate limits (docs/parent-link-v1.md §6.3), with the real defaults: pairing lookups
// 10 a minute, other calls without a valid token 60 a minute. Plus the values of every limit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS } from "../lib/relay.mjs";
import { limitKey } from "../lib/ratelimit.mjs";
import { openRelay, call, setupChannel, newToken, channelId, fakeBox, fakeIp, expectError } from "./helpers.mjs";

const lookup = (r, slot, ip, token) => call(r.base, "GET", `/v1/pair/${slot}`, { ip, token });

async function relayWithSlot(t, options) {
  const r = await openRelay(t, options);
  const s = await setupChannel(r, { devices: 1 });
  const slot = channelId();
  const put = await call(r.base, "PUT", `/v1/pair/${slot}`, { token: s.computer.token, body: { ch: s.ch, hello: fakeBox() } });
  assert.equal(put.status, 201);
  return { r, s, slot };
}

test("the limits are those of §6.3", async (t) => {
  assert.ok(Object.isFrozen(LIMITS));
  assert.equal(LIMITS.channels, 8);
  assert.equal(LIMITS.devicesPerChannel, 8);
  assert.equal(LIMITS.waitingPerChannel, 2);
  assert.equal(LIMITS.pairLookupsPerMinute, 10);
  assert.equal(LIMITS.unauthenticatedPerMinute, 60);
  assert.equal(LIMITS.bodyBytes, 300 * 1024);
  assert.equal(LIMITS.requestTimeoutMs, 40_000);
  assert.equal(LIMITS.maxWaitSeconds, 25);
  assert.equal(LIMITS.stateCopyBytes, 256 * 1024);
  assert.equal(LIMITS.commandBoxBytes, 16 * 1024);
  assert.equal(LIMITS.commandsPerChannel, 500);
  assert.equal(LIMITS.commandMaxAgeMs, 14 * 86_400_000);
  assert.equal(LIMITS.pairSlotMs, 10 * 60_000);
  assert.equal(LIMITS.pairMessagesPerDirection, 4);
  assert.equal(LIMITS.pairSlotsPerChannel, 4);
  assert.equal(LIMITS.unlinkedMarkerMs, 30 * 86_400_000);
  const r = await openRelay(t);
  assert.equal(r.server.requestTimeout, 40_000);
});

test("pairing lookups: 10 a minute per address; the 11th → 429 with Retry-After; other addresses are unaffected; it refills", async (t) => {
  const { r, slot } = await relayWithSlot(t);
  const ip = "198.51.100.7";
  for (let i = 0; i < 10; i++) {
    const hit = i % 2 === 0;
    assert.equal((await lookup(r, hit ? slot : channelId(), ip)).status, hit ? 200 : 404, "hits and misses both count");
  }
  const limited = await lookup(r, slot, ip);
  expectError(limited, 429, "rate_limited");
  assert.equal(limited.headers.get("retry-after"), "6");
  assert.equal((await lookup(r, slot, "198.51.100.8")).status, 200, "another address");
  assert.equal((await call(r.base, "GET", "/v1/health", { ip })).status, 200, "other calls have their own allowance");

  // One lookup comes back every 6 seconds…
  r.clock.now += 6000;
  assert.equal((await lookup(r, slot, ip)).status, 200);
  expectError(await lookup(r, slot, ip), 429, "rate_limited");
  // …and all ten after a minute.
  r.clock.now += 60_000;
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, ip)).status, 200);
  expectError(await lookup(r, slot, ip), 429, "rate_limited");
});

test("GET /v1/pair/{slot} counts as a lookup even with a valid token", async (t) => {
  const { r, s, slot } = await relayWithSlot(t);
  const ip = fakeIp();
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, ip, s.computer.token)).status, 200);
  expectError(await lookup(r, slot, ip, s.computer.token), 429, "rate_limited");
  expectError(await lookup(r, slot, ip, s.phones[0].token), 429, "rate_limited");
});

test("a 404 on a slot from POST toComputer or GET toPhone costs a lookup; hits don't", async (t) => {
  const { r, slot } = await relayWithSlot(t);

  const hits = fakeIp();
  for (let i = 0; i < 4; i++) assert.equal((await call(r.base, "POST", `/v1/pair/${slot}/toComputer`, { ip: hits, body: { box: fakeBox() } })).status, 201);
  for (let i = 0; i < 10; i++) assert.equal((await call(r.base, "GET", `/v1/pair/${slot}/toPhone`, { ip: hits })).status, 200);
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, hits)).status, 200, "no lookups used up yet");
  expectError(await lookup(r, slot, hits), 429, "rate_limited");

  const postMisses = fakeIp();
  for (let i = 0; i < 10; i++) {
    expectError(await call(r.base, "POST", `/v1/pair/${channelId()}/toComputer`, { ip: postMisses, body: { box: fakeBox() } }), 404, "not_found");
  }
  expectError(await call(r.base, "POST", `/v1/pair/${channelId()}/toComputer`, { ip: postMisses, body: { box: fakeBox() } }), 429, "rate_limited");
  expectError(await lookup(r, slot, postMisses), 429, "rate_limited");

  const readMisses = fakeIp();
  for (let i = 0; i < 10; i++) expectError(await call(r.base, "GET", `/v1/pair/${channelId()}/toPhone`, { ip: readMisses }), 404, "not_found");
  const limited = await call(r.base, "GET", `/v1/pair/${channelId()}/toPhone`, { ip: readMisses });
  expectError(limited, 429, "rate_limited");
  assert.ok(Number(limited.headers.get("retry-after")) >= 1);
  expectError(await lookup(r, slot, readMisses), 429, "rate_limited");
});

test("calls without a valid token: 60 a minute per address; the 61st → 429 with Retry-After; other addresses are unaffected; it refills", async (t) => {
  const r = await openRelay(t);
  const ip = fakeIp();
  for (let i = 0; i < 60; i++) assert.equal((await call(r.base, "GET", "/v1/health", { ip })).status, 200);
  const limited = await call(r.base, "GET", "/v1/health", { ip });
  expectError(limited, 429, "rate_limited");
  assert.equal(limited.headers.get("retry-after"), "1");

  // Everything without a registered token shares that allowance.
  expectError(await call(r.base, "GET", "/v1/nope", { ip }), 429, "rate_limited");
  expectError(await call(r.base, "GET", `/v1/ch/${channelId()}/state`, { ip, token: newToken().token }), 429, "rate_limited");
  const fresh = newToken();
  const create = await call(r.base, "PUT", `/v1/channels/${channelId()}`, { ip, token: fresh.token, body: { setupCode: r.relay.setupCode, tokenHash: fresh.hash } });
  expectError(create, 429, "rate_limited");

  assert.equal((await call(r.base, "GET", "/v1/health", { ip: fakeIp() })).status, 200, "another address");

  r.clock.now += 1000;
  assert.equal((await call(r.base, "GET", "/v1/health", { ip })).status, 200, "one more a second later");
  expectError(await call(r.base, "GET", "/v1/health", { ip }), 429, "rate_limited");
  r.clock.now += 60_000;
  for (let i = 0; i < 60; i++) assert.equal((await call(r.base, "GET", "/v1/health", { ip })).status, 200);
  expectError(await call(r.base, "GET", "/v1/health", { ip }), 429, "rate_limited");
});

test("calls with a registered computer or device token aren't limited, even from an address that has used up its allowance", async (t) => {
  const r = await openRelay(t);
  const s = await setupChannel(r, { devices: 1 });
  const [p] = s.phones;
  await call(r.base, "PUT", `/v1/ch/${s.ch}/state`, { token: s.computer.token, body: { seq: 1, copies: { [p.id]: fakeBox() } } });
  const ip = fakeIp();
  for (let i = 0; i < 60; i++) await call(r.base, "GET", "/v1/health", { ip });
  expectError(await call(r.base, "GET", "/v1/health", { ip }), 429, "rate_limited");

  for (let i = 0; i < 100; i++) {
    assert.equal((await call(r.base, "GET", `/v1/ch/${s.ch}/cmd`, { token: s.computer.token, ip })).status, 200);
    assert.equal((await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: p.token, ip })).status, 200);
  }
  // A registered token where it doesn't belong is refused for that, not for the rate.
  expectError(await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: s.computer.token, ip }), 401, "unauthorized");
  assert.equal((await call(r.base, "GET", "/v1/health", { token: p.token, ip })).status, 200);
  // A well-formed token the relay doesn't know is unauthenticated, and limited.
  expectError(await call(r.base, "GET", `/v1/ch/${s.ch}/state`, { token: newToken().token, ip }), 429, "rate_limited");
});

test("behind a loopback proxy the last X-Forwarded-For entry is the client", async (t) => {
  const { r, slot } = await relayWithSlot(t);
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, "1.2.3.4, 203.0.113.9")).status, 200);
  expectError(await lookup(r, slot, "203.0.113.9"), 429, "rate_limited");
  expectError(await lookup(r, slot, "10.9.9.9, 192.168.0.1,203.0.113.9"), 429, "rate_limited");
  assert.equal((await lookup(r, slot, "203.0.113.9, 203.0.113.10")).status, 200, "a different last entry is a different client");

  // Something that isn't an address counts as the connection's own address (loopback here).
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, "not-an-address")).status, 200);
  expectError(await lookup(r, slot, undefined), 429, "rate_limited");
});

test("with trustProxy off, X-Forwarded-For is ignored", async (t) => {
  const { r, slot } = await relayWithSlot(t, { trustProxy: false });
  for (let i = 0; i < 10; i++) assert.equal((await lookup(r, slot, fakeIp())).status, 200);
  expectError(await lookup(r, slot, fakeIp()), 429, "rate_limited");
});

test("IPv6 clients are limited per /64", async (t) => {
  const { r, slot } = await relayWithSlot(t);
  for (let i = 1; i <= 10; i++) assert.equal((await lookup(r, slot, `2001:db8:1:2::${i.toString(16)}`)).status, 200);
  expectError(await lookup(r, slot, "2001:db8:1:2:ffff:ffff:ffff:ffff"), 429, "rate_limited");
  expectError(await lookup(r, slot, "2001:0DB8:0001:0002:0:0:0:abcd"), 429, "rate_limited");
  assert.equal((await lookup(r, slot, "2001:db8:1:3::1")).status, 200, "the next /64");

  assert.equal(limitKey("2001:DB8:0001:0002::1"), "2001:db8:1:2::/64");
  assert.equal(limitKey("::ffff:192.0.2.1"), "192.0.2.1");
  assert.equal(limitKey("192.0.2.1"), "192.0.2.1");
  assert.equal(limitKey("::1"), "0:0:0:0::/64");
});

test("TC_TRUST_PROXY: loopback by default, private networks for Docker, a list of ranges, or nobody", async () => {
  const { proxyTrust, clientAddress } = await import("../lib/ratelimit.mjs");
  const req = (remote, xff) => ({ socket: { remoteAddress: remote }, headers: xff ? { "x-forwarded-for": xff } : {} });

  const loopback = proxyTrust("loopback");
  assert.ok(loopback("127.0.0.1") && loopback("::1") && loopback("::ffff:127.0.0.1"));
  assert.ok(!loopback("172.17.0.1") && !loopback("203.0.113.9"));
  assert.equal(clientAddress(req("127.0.0.1", "198.51.100.7"), loopback), "198.51.100.7");
  assert.equal(clientAddress(req("172.17.0.1", "198.51.100.7"), loopback), "172.17.0.1", "Docker's bridge isn't believed by default");
  assert.equal(clientAddress(req("127.0.0.1", "1.1.1.1, 198.51.100.7"), loopback), "198.51.100.7", "only the last entry counts");
  assert.equal(clientAddress(req("127.0.0.1", "not an address"), loopback), "127.0.0.1");

  const docker = proxyTrust("private");
  assert.ok(docker("172.17.0.1") && docker("::ffff:172.18.0.1") && docker("10.1.2.3") && docker("192.168.1.10") && docker("100.101.102.103") && docker("fd00::1"));
  assert.ok(!docker("203.0.113.9") && !docker("2001:db8::1"));
  assert.equal(clientAddress(req("172.17.0.1", "198.51.100.7"), docker), "198.51.100.7");

  const list = proxyTrust("172.17.0.1, 10.0.0.0/8");
  assert.ok(list("172.17.0.1") && list("10.9.8.7") && list("127.0.0.1"));
  assert.ok(!list("172.17.0.2") && !list("192.168.0.1"));

  for (const off of ["0", "off", false]) {
    assert.equal(clientAddress(req("127.0.0.1", "198.51.100.7"), proxyTrust(off)), "127.0.0.1", String(off));
  }
  assert.ok(proxyTrust(true)("127.0.0.1"));
  for (const bad of ["nonsense", "10.0.0.0/33", "1.2.3.4/8/9"]) assert.throws(() => proxyTrust(bad), /TC_TRUST_PROXY/, bad);
});
