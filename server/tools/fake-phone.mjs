#!/usr/bin/env node
// A stand-in for a parent's phone. It runs the parent app's own protocol code
// (parent/js/phone.js): pairs by code, sends every command type, and checks what the computer
// did with each one.
//
//   node server/tools/fake-phone.mjs --server http://localhost:8787 --code ABCDE-FGHJK [--name "Test Phone"] [--pair-only]
//
// It prints one line per check and exits with 1 if any failed. --pair-only stops after pairing.
import { fileURLToPath } from "node:url";
import * as phone from "../../parent/js/phone.js";
import * as lc from "../../parent/js/linkcrypto.js";

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

export class FakePhone {
  constructor({ server, name = "Test Phone", log = () => {} }) {
    this.server = server.replace(/\/+$/, "");
    this.name = name;
    this.log = log;
    this.counters = new Map();
    this.store = {
      getCounter: async (id) => this.counters.get(id) ?? 0,
      setCounter: async (id, n) => void this.counters.set(id, n),
    };
    this.reset();
  }

  reset() {
    this.etag = null;
    this.lastSeq = -1;
    this.state = null;
    this.meta = null;
    this.live = null;
  }

  async pair(code, { onStep } = {}) {
    this.computer = await phone.pair({
      origin: this.server,
      code,
      deviceName: this.name,
      onStep: (s) => {
        if (s.step === "compare") this.comparison = s.comparison;
        onStep?.(s);
      },
    });
    return this.computer;
  }

  send(type, args, options = {}) {
    return phone.sendCommand({ computer: this.computer, store: this.store, type, args, ...options });
  }

  async refresh() {
    const r = await phone.fetchState({ computer: this.computer, etag: this.etag, lastSeq: this.lastSeq });
    if (r.kind === "state") {
      this.state = r.state;
      this.etag = r.etag;
      this.meta = r.meta;
      this.lastSeq = r.state.seq;
    }
    if (r.live) this.live = r.live;
    return r;
  }

  /** Refreshes until `test(state)` returns something truthy, and returns it. */
  async waitFor(test, { timeout = 15_000, what = "the state to change" } = {}) {
    const end = Date.now() + timeout;
    for (;;) {
      try {
        await this.refresh();
        const got = this.state && test(this.state);
        if (got) return got;
      } catch (e) {
        if (e.code !== "network") throw e;
      }
      if (Date.now() > end) throw new Error(`Timed out waiting for ${what}`);
      await new Promise((resolve) => setTimeout(resolve, 60));
    }
  }

  /** Waits for the computer's result for a sent command. */
  result(sent, options) {
    return this.waitFor((s) => phone.resultFor(s, this.computer.deviceId, sent.id), { what: `the result of ${sent.type}`, ...options });
  }

  async run(type, args, options) {
    const sent = await this.send(type, args, options);
    return { sent, result: await this.result(sent) };
  }
}

/**
 * Sends every command type of §7 and checks the effect on the state. Returns
 * [{ name, ok, detail }]. `removeId`, if given, is another phone to remove at the end.
 */
export async function runAll(p, { removeId } = {}) {
  const checks = [];
  const check = (name, ok, detail = "") => {
    checks.push({ name, ok: !!ok, detail });
    p.log(`${ok ? "ok  " : "FAIL"} ${name}${detail && !ok ? " — " + detail : ""}`);
  };
  const expect = async (name, type, args, outcome, verify = () => true, reason) => {
    try {
      const { result } = await p.run(type, args);
      const ok = result.outcome === outcome && (reason === undefined || result.reason === reason);
      const verified = ok && (await verify(p.state));
      check(name, ok && verified, `got ${result.outcome}${result.reason ? " (" + result.reason + ")" : ""}${ok && !verified ? ", but the state doesn't show it" : ""}`);
    } catch (e) {
      check(name, false, e.message);
    }
  };
  await p.refresh();
  const now = Date.now();
  const caps = p.state?.computer?.capabilities ?? [];
  check("state arrives and opens", p.state?.v === 1, "no state");
  check("computer lists its capabilities", caps.includes("lock"), JSON.stringify(caps));

  const hour = now + 60 * MINUTE;
  await expect("lock until a time, homework apps allowed", "lock", { until: hour, strength: "homework" }, "applied",
    (s) => s.access.mode === "locked" && s.access.until === hour && s.access.strength === "homework" && s.lock.locked && s.lock.reasons.some((r) => r.kind === "parent"));
  await expect("lock until lifted, everything closed", "lock", { until: null, strength: "all", note: "Dinner first" }, "applied",
    (s) => s.access.mode === "locked" && s.access.until === null && s.access.strength === "all");
  await expect("unlock until a time", "free", { until: now + 30 * MINUTE }, "applied", (s) => s.access.mode === "free" && !s.lock.locked);
  await expect("back to normal", "normal", {}, "applied", (s) => s.access.mode === "normal");
  await expect("back to normal again is a no-op", "normal", {}, "noop");

  const taskId = lc.uuid();
  const due = now + 2 * DAY;
  await expect("add a task", "addTask", { task: { id: taskId, title: "Fake phone task", details: "Sent by the test", due } }, "applied",
    (s) => s.tasks.some((t) => t.id === taskId && t.title === "Fake phone task" && t.due === due && t.status === "pending"));
  await expect("adding the same task again is a no-op", "addTask", { task: { id: taskId, title: "Fake phone task", details: "", due } }, "noop");
  await expect("edit a task", "editTask", { id: taskId, title: "Fake phone task, edited", due: due + 60 * MINUTE }, "applied",
    (s) => s.tasks.some((t) => t.id === taskId && t.title === "Fake phone task, edited" && t.due === due + 60 * MINUTE));
  await expect("excuse a task", "excuseTask", { id: taskId }, "applied", (s) => s.tasks.some((t) => t.id === taskId && t.status === "excused"));
  await expect("delete a task", "deleteTask", { id: taskId }, "applied", (s) => !s.tasks.some((t) => t.id === taskId));
  await expect("deleting it again is a no-op", "deleteTask", { id: taskId }, "noop");
  await expect("editing a missing task is rejected", "editTask", { id: lc.uuid(), title: "Nope" }, "rejected", () => true, "not_found");

  const withProof = p.state.tasks.find((t) => t.status === "pending" && t.proofs?.some((x) => x.verdict !== "guardianApproved"));
  if (withProof) {
    const proof = withProof.proofs.at(-1);
    await expect("approve a specific proof", "approveProof", { taskId: withProof.id, proofId: proof.id }, "applied",
      (s) => s.tasks.some((t) => t.id === withProof.id && (t.status === "proven" || t.status === "provenLate") && t.proofs.some((x) => x.id === proof.id && x.verdict === "guardianApproved")));
    await expect("approving a settled task is a no-op", "approveProof", { taskId: withProof.id, proofId: proof.id }, "noop");
  } else {
    check("approve a specific proof", false, "no pending task with a proof to approve");
  }

  const repeatId = lc.uuid();
  const today = new Date(now);
  const startDate = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`;
  await expect("add a repeating task (weeks, chosen days)", "addRepeat",
    { repeat: { id: repeatId, title: "Water the plants", details: "", unit: "weeks", interval: 1, weekdays: [2, 5], minuteOfDay: 17 * 60, startDate } }, "applied",
    (s) => s.repeats.some((r) => r.id === repeatId && r.unit === "weeks" && r.weekdays.join() === "2,5" && typeof r.schedule === "string"));
  const everyId = lc.uuid();
  await expect("add a repeating task (every N days)", "addRepeat",
    { repeat: { id: everyId, title: "Stretch", details: "Ten minutes.", unit: "days", interval: 3, weekdays: [], minuteOfDay: 7 * 60 + 15, startDate } }, "applied",
    (s) => s.repeats.some((r) => r.id === everyId && r.unit === "days" && r.interval === 3));
  await expect("stop a repeat", "stopRepeat", { id: repeatId }, "applied", (s) => !s.repeats.some((r) => r.id === repeatId));
  await expect("stop the other repeat", "stopRepeat", { id: everyId }, "applied", (s) => !s.repeats.some((r) => r.id === everyId));

  const calc = { id: "com.apple.calculator", name: "Calculator" };
  await expect("allow an app during locks", "allowApp", { app: calc }, "applied", (s) => s.apps.allowed.some((a) => a.id === calc.id));
  await expect("stop allowing it", "disallowApp", { app: calc }, "applied", (s) => !s.apps.allowed.some((a) => a.id === calc.id));
  const game = { id: "com.mojang.minecraftlauncher", name: "Minecraft" };
  await expect("block an app", "blockApp", { app: game }, "applied", (s) => s.apps.blocked.some((a) => a.id === game.id));
  await expect("unblock it", "unblockApp", { app: game }, "applied", (s) => !s.apps.blocked.some((a) => a.id === game.id));

  const penalty = (p.state.settings.penaltyMinutes === 45 ? 50 : 45);
  await expect("set the late penalty", "setPenalty", { minutes: penalty }, "applied", (s) => s.settings.penaltyMinutes === penalty);
  await expect("turn extensions off", "setExtensions", { enabled: false }, "applied", (s) => s.settings.extensionsEnabled === false);
  await expect("turn extensions on", "setExtensions", { enabled: true }, "applied", (s) => s.settings.extensionsEnabled === true);
  const text = "Dinner at 7. Finish the worksheet first.";
  await expect("message the student", "message", { text }, "applied", (s) => (typeof s.message === "string" ? s.message : s.message?.text) === text);

  if (caps.includes("guardianSetup")) {
    await expect("let the computer set a new guardian code", "allowGuardianSetup", { until: Date.now() + 10 * MINUTE }, "applied");
    await expect("a time that has passed changes nothing", "allowGuardianSetup", { until: Date.now() - MINUTE }, "noop");
  }
  await expect("an unknown command is unsupported", "makeCoffee", { strength: "double" }, "unsupported");
  await expect("bad arguments are rejected", "lock", { until: null, strength: "extreme" }, "rejected", () => true, "bad_args");
  await expect("arguments not listed are rejected", "setPenalty", { minutes: 10, extra: true }, "rejected", () => true, "bad_args");

  if (removeId) {
    await expect("remove another phone", "removeDevice", { id: removeId }, "applied", (s) => !s.devices.some((d) => d.id === removeId));
  }
  return checks;
}

async function main() {
  const args = process.argv.slice(2);
  const opt = (name, fallback) => {
    const i = args.indexOf("--" + name);
    return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
  };
  const code = opt("code");
  if (!code) {
    console.error("Pass the pairing code the computer shows: --code ABCDE-FGHJK");
    process.exit(2);
  }
  const p = new FakePhone({ server: opt("server", "http://localhost:8787"), name: opt("name", "Test Phone"), log: (line) => console.log(line) });
  await p.pair(code, {
    onStep: (s) => {
      if (s.step === "hello") console.log(`Found ${s.computerName}.`);
      if (s.step === "compare") console.log(`Comparison code: ${lc.formatComparisonCode(s.comparison)}. Waiting for the computer to approve…`);
    },
  });
  console.log(`Paired with ${p.computer.computerName} as ${p.computer.deviceName}.`);
  if (args.includes("--pair-only")) process.exit(0);
  const checks = await runAll(p);
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length} of ${checks.length} checks passed.`);
  process.exit(failed.length ? 1 : 0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
