#!/usr/bin/env node
// Tax Collector relay server. Passes sealed messages between Tax Collector and the parents'
// phones, and serves the parent app. See README.md here, and docs/parent-link-v1.md.
//
//   node server.mjs                 start (PORT, HOST, TC_DATA_DIR and others from the environment)
//   node server.mjs --setup-code    show the setup code of the data folder and exit
//   node server.mjs PORT SETUPCODE  for test scripts: that port, that setup code, and a new empty
//                                   data folder that's deleted on exit (unless TC_DATA_DIR is set)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Relay } from "./lib/relay.mjs";
import { proxyTrust } from "./lib/ratelimit.mjs";
import { formatSetupCode, normaliseCode } from "./lib/util.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const [major] = process.versions.node.split(".").map(Number);
if (major < 22) {
  console.error(`Tax Collector's relay needs Node 22 or newer (this is ${process.version}).`);
  process.exit(1);
}

const fail = (message) => {
  console.error(message);
  process.exit(2);
};

const env = { ...process.env };
// Test scripts start a relay as `node server.mjs PORT SETUPCODE` and want a clean one each time.
const positional = process.argv.slice(2).filter((a) => !a.startsWith("--"));
let scratch = null;
if (positional.length) {
  if (positional.length > 2) fail("Usage: node server.mjs [PORT [SETUPCODE]], or set PORT and TC_SETUP_CODE.");
  env.PORT = positional[0];
  if (positional[1]) env.TC_SETUP_CODE = positional[1];
}
const port = Number(env.PORT || 8787);
const host = env.HOST || "127.0.0.1";
if (!/^\d+$/.test(String(env.PORT || 8787)) || port > 65535) fail(`PORT must be a number from 0 to 65535, not "${env.PORT}".`);
if (env.TC_SETUP_CODE && normaliseCode(env.TC_SETUP_CODE).length !== 12) {
  fail("The setup code must have 12 letters and numbers from Crockford's base32 (0-9 and A-Z without I, L, O, U), like ABCD-EFGH-JKMN.");
}
if (positional.length && !env.TC_DATA_DIR && !process.argv.includes("--setup-code")) {
  env.TC_DATA_DIR = scratch = fs.mkdtempSync(path.join(os.tmpdir(), "tc-relay-"));
}
const dataDir = path.resolve(env.TC_DATA_DIR || path.join(here, "data"));
const staticRoot = path.resolve(env.TC_PARENT_DIR || path.join(here, "..", "parent"));
let trustProxy;
try {
  trustProxy = proxyTrust(env.TC_TRUST_PROXY ?? "loopback");
} catch (e) {
  fail(e.message);
}

// Only reads: it never makes a data folder or touches a running server's files.
if (process.argv.includes("--setup-code")) {
  if (env.TC_SETUP_CODE) {
    console.log(formatSetupCode(normaliseCode(env.TC_SETUP_CODE)));
    process.exit(0);
  }
  let info = null;
  try {
    info = JSON.parse(fs.readFileSync(path.join(dataDir, "server.json"), "utf8"));
  } catch {
    // reported below
  }
  if (typeof info?.setupCode !== "string") {
    fail(`No setup code in ${dataDir} yet. Start the server once, or set TC_DATA_DIR to the data folder it uses.`);
  }
  console.log(formatSetupCode(info.setupCode));
  process.exit(0);
}

let relay;
try {
  relay = await Relay.open({
    dataDir,
    staticRoot,
    setupCode: env.TC_SETUP_CODE || undefined,
    trustProxy,
    logRequests: env.TC_LOG_REQUESTS === "1",
  });
} catch (e) {
  fail(`Couldn't open the data folder ${dataDir}: ${e.message}`);
}

const server = relay.createServer();
server.on("error", (e) => {
  console.error(e.code === "EADDRINUSE" ? `Port ${port} is already in use.` : `Couldn't start: ${e.message}`);
  process.exit(1);
});
server.listen(port, host, () => {
  const where = `http://${host.includes(":") ? `[${host}]` : host}:${server.address().port}`;
  console.log(`Tax Collector relay listening on ${where}`);
  console.log(`Data folder: ${relay.dataDir}${scratch ? " (temporary: deleted when the relay stops)" : ""}`);
  if (relay.firstStart && !scratch) {
    const again = `TC_DATA_DIR="${relay.dataDir}" node "${fileURLToPath(import.meta.url)}" --setup-code`;
    console.log("");
    console.log(`  Setup code: ${formatSetupCode(relay.setupCode)}`);
    console.log("");
    console.log("  Type it into Tax Collector on each computer, with this server's address.");
    console.log(`  It's saved in ${path.join(relay.dataDir, "server.json")}. To see it again:`);
    console.log(`  ${again}`);
    console.log("");
  }
});

const sweeper = setInterval(() => relay.sweep(), 30_000);
sweeper.unref();

let stopping = false;
async function stop(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`Stopping (${signal})…`);
  clearInterval(sweeper);
  server.close();
  server.closeIdleConnections?.();
  await relay.close();
  if (scratch) fs.rmSync(scratch, { recursive: true, force: true });
  setTimeout(() => process.exit(0), 200).unref();
  server.closeAllConnections?.();
}
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));
