// The parent app's logic that doesn't need a browser: plain-words status, freshness from the
// server's clock, where a command is, schedules, day sections, time zones. Plus checks on the
// app's files: no HTML from strings, nothing the CSP forbids, and one list of files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import * as f from "../../parent/js/format.js";
import * as phone from "../../parent/js/phone.js";
import { FILES } from "../lib/static.mjs";

f.setLocale("en-US");
const TZ = "America/Toronto";
const PARENT = fileURLToPath(new URL("../../parent/", import.meta.url));
const at = (y, m, d, h, min = 0) => f.wallTime(y, m, d, h * 60 + min, TZ);
const NOW = at(2026, 10, 19, 20, 0); // Monday, October 19, 8:00 PM in Toronto

const state = (over = {}) => ({
  v: 1, seq: 1, computer: { name: "Test Mac", timeZone: TZ, capabilities: ["lock"] },
  access: { mode: "normal", until: null, strength: null, by: "", at: 0 },
  lock: { locked: false, reasons: [] }, tasks: [], results: [], ...over,
});
const task = (over) => ({ id: over.id ?? crypto.randomUUID(), title: "Task", due: NOW + 3600_000, status: "pending", proofs: [], ...over });

test("times are the computer's: wall clock round trips, across a daylight-saving change", () => {
  for (const [y, m, d, min] of [[2026, 10, 19, 1200], [2026, 11, 1, 90], [2026, 11, 1, 150], [2026, 3, 8, 180], [2026, 12, 31, 1439]]) {
    const ms = f.wallTime(y, m, d, min, TZ);
    const z = f.zoned(ms, TZ);
    assert.deepEqual([z.y, z.m, z.d, z.minute], [y, m, d, min], `${y}-${m}-${d} ${min}`);
  }
  assert.equal(f.time(NOW, TZ), "8:00 PM");
  assert.equal(f.dayName(NOW, NOW, TZ), "Today");
  assert.equal(f.dayName(at(2026, 10, 20, 8), NOW, TZ), "Tomorrow");
  assert.equal(f.dayName(at(2026, 10, 22, 8), NOW, TZ), "Thursday, October 22");
  assert.equal(f.when(at(2026, 10, 20, 8), NOW, TZ), "tomorrow 8:00 AM");
  assert.equal(f.zoneOf({ computer: { timeZone: "Not/AZone" } }), undefined);
  assert.equal(f.zoneOf({ computer: { timeZone: TZ } }), TZ);
});

test("until a time means the next time the clock shows it", () => {
  assert.equal(f.nextClockTime("21:00", NOW, TZ), at(2026, 10, 19, 21));
  assert.equal(f.nextClockTime("07:30", NOW, TZ), at(2026, 10, 20, 7, 30));
  assert.equal(f.nextClockTime("20:00", NOW, TZ), at(2026, 10, 20, 20), "now is past, so tomorrow");
  assert.equal(f.nextClockTime("", NOW, TZ), null);
});

test("status in plain words: “Locked since 7:02 PM: Math worksheet overdue”", () => {
  const w = task({ id: "a", title: "Math worksheet", due: at(2026, 10, 19, 19, 2) });
  const s = f.statusSummary(state({ tasks: [w], lock: { locked: true, reasons: [{ kind: "overdue", taskId: "a", title: "Math worksheet" }] } }), NOW);
  assert.equal(s.tone, "locked");
  assert.equal(s.headline, "Locked since 7:02 PM: Math worksheet overdue");

  const two = f.statusSummary(state({ tasks: [w, task({ id: "b", title: "Essay", due: at(2026, 10, 19, 19, 30) })],
    lock: { locked: true, reasons: [{ kind: "overdue", taskId: "b" }, { kind: "overdue", taskId: "a" }] } }), NOW);
  assert.equal(two.headline, "Locked since 7:02 PM: Math worksheet and 1 more overdue");

  const parent = f.statusSummary(state({ access: { mode: "locked", until: at(2026, 10, 19, 21), strength: "all", by: "Mom's iPhone", at: at(2026, 10, 19, 19, 45) },
    lock: { locked: true, reasons: [{ kind: "parent", title: "Mom's iPhone", until: at(2026, 10, 19, 21) }] } }), NOW);
  assert.equal(parent.headline, "Locked by Mom's iPhone until 9:00 PM");
  assert.match(parent.detail, /since 7:45 PM, everything closed/);

  const lifted = f.statusSummary(state({ access: { mode: "locked", until: null, strength: "homework", by: "Dad's Pixel", at: 0 }, lock: { locked: true, reasons: [{ kind: "parent" }] } }), NOW);
  assert.equal(lifted.headline, "Locked by Dad's Pixel until someone unlocks it");
  assert.match(lifted.detail, /homework apps allowed/);

  const penalty = f.statusSummary(state({ lock: { locked: true, reasons: [{ kind: "penalty", taskId: "a", title: "Essay", until: at(2026, 10, 19, 20, 30) }] } }), NOW);
  assert.equal(penalty.headline, "Locked until 8:30 PM: late penalty for Essay");

  const guardian = f.statusSummary(state({ access: { mode: "locked", until: null, strength: "all", by: "your guardian", at: 0 }, lock: { locked: true, reasons: [{ kind: "parent", title: "your guardian" }] } }), NOW);
  assert.equal(guardian.headline, "Locked by a parent at the computer until someone unlocks it", "the Mac's words for the student, reworded");
  const byGuardian = f.statusSummary(state({ access: { mode: "free", until: at(2026, 10, 19, 22), by: "your guardian", at: 0 } }), NOW);
  assert.match(byGuardian.detail, /^By a parent at the computer\./);

  const free = f.statusSummary(state({ access: { mode: "free", until: at(2026, 10, 19, 22), by: "Mom's iPhone", at: 0 } }), NOW);
  assert.equal(free.tone, "free");
  assert.equal(free.headline, "Unlocked until 10:00 PM");

  const ok = f.statusSummary(state({ tasks: [task({ title: "Read chapter 7", due: at(2026, 10, 20, 8) })] }), NOW);
  assert.deepEqual([ok.tone, ok.headline, ok.detail], ["ok", "Not locked", "Next: Read chapter 7, due tomorrow 8:00 AM."]);
  assert.equal(f.statusSummary(state(), NOW).detail, "Nothing is due.");
});

test("freshness comes from the server's clock only: serverTime − computerSeen", () => {
  const t = 1_800_000_000_000;
  assert.equal(f.freshness({ serverTime: t, computerSeen: t - 5_000, computerAwake: true }, TZ).tone, "ok");
  assert.equal(f.freshness({ serverTime: t, computerSeen: t - 5 * 60_000, computerAwake: true }, TZ).text, "Last heard from 5 minutes ago");
  assert.equal(f.freshness({ serverTime: t, computerSeen: t - 3600_000, computerAwake: true }, TZ).tone, "silent");
  const asleep = f.freshness({ serverTime: NOW, computerSeen: at(2026, 10, 19, 19, 45), computerAwake: false }, TZ);
  assert.deepEqual([asleep.tone, asleep.text], ["asleep", "Asleep since 7:45 PM"]);
  assert.equal(f.freshness(null, TZ).tone, "unknown");
  assert.equal(f.freshness({ serverTime: t, computerSeen: 0 }, TZ).tone, "silent");
});

test("every command shows Sending… / Delivered / Applied / Rejected (reason) / Waiting: computer asleep", () => {
  const dev = "6f1c0e3a-2b4d-4c8e-9a1f-0d2e3c4b5a69";
  const cmd = { id: "c1", seq: null };
  const live = { serverTime: 1000, computerSeen: 1000, computerAwake: true };
  const phase = (c, ctx) => phone.commandPhase(c, { deviceId: dev, state: null, meta: { ackedUpTo: 0 }, live, ...ctx });
  const label = (c, ctx) => f.phaseLabel(phase(c, ctx), ctx?.live ?? live).text;

  assert.equal(label(cmd), "Sending…");
  assert.equal(label({ ...cmd, seq: 5 }), "Sent");
  assert.equal(label({ ...cmd, seq: 5 }, { live: { ...live, computerAwake: false } }), "Waiting: computer asleep");
  assert.equal(label({ ...cmd, seq: 5 }, { live: { serverTime: 500_000, computerSeen: 1000, computerAwake: true } }), "Waiting: computer offline");
  assert.equal(label({ ...cmd, seq: 5 }, { meta: { ackedUpTo: 5 } }), "Delivered");
  const result = (outcome, reason = "", id = "c1", d = dev) => ({ dev: d, n: 1, id, type: "lock", outcome, reason, at: 1 });
  assert.equal(label({ ...cmd, seq: 5 }, { state: { results: [result("applied")] } }), "Applied");
  assert.equal(label({ ...cmd, seq: 5 }, { state: { results: [result("rejected", "stale")] } }), "Rejected (this phone's clock is off by more than 10 minutes)");
  assert.equal(label({ ...cmd, seq: 5 }, { state: { results: [result("unsupported")] } }), "Not supported on this computer");
  assert.match(label({ ...cmd, seq: 5 }, { state: { results: [result("noop", "That time has passed.")] } }), /^Nothing to change/);
  // Another phone's result for the same ID, or another command's, isn't ours.
  assert.equal(label({ ...cmd, seq: 5 }, { state: { results: [result("applied", "", "c2"), result("applied", "", "c1", "other")] } }), "Sent");
  // A resend's "replayed" never hides the real answer.
  assert.equal(phone.resultFor({ results: [result("applied"), result("rejected", "replayed")] }, dev, "c1").outcome, "applied");
  assert.equal(phone.resultFor({ results: [result("rejected", "replayed"), result("applied")] }, dev, "c1").outcome, "applied");
  // A final answer is kept once seen, after the result scrolls out of the state's last 50.
  assert.equal(label({ ...cmd, seq: 5, final: { outcome: "applied", reason: "" } }, { state: { results: [] } }), "Applied");
  assert.equal(label({ ...cmd, error: "Can't reach the server." }), "Not sent: Can't reach the server.");
  assert.ok(f.isFinal("rejected") && !f.isFinal("delivered"));
});

test("a phone behind the computer's counter catches up from a “replayed” result", async () => {
  const counters = new Map([["x", 10]]);
  const store = { getCounter: async (id) => counters.get(id), setCounter: async (id, n) => counters.set(id, n) };
  const computer = { id: "x", deviceId: "d" };
  const st = { results: [{ dev: "d", reason: "replayed", last: 1234 }, { dev: "other", reason: "replayed", last: 99999 }] };
  assert.equal(await phone.catchUpCounter(st, computer, store), true);
  assert.equal(counters.get("x"), 1234);
  assert.equal(await phone.catchUpCounter(st, computer, store), false);
});

test("repeats read like the Mac", () => {
  assert.equal(f.scheduleText({ unit: "weeks", interval: 1, weekdays: [2, 3, 4, 5, 6], minuteOfDay: 18 * 60 }), "Every weekday at 6:00 PM");
  assert.equal(f.scheduleText({ unit: "weeks", interval: 1, weekdays: [1, 2, 3, 4, 5, 6, 7], minuteOfDay: 8 * 60 }), "Every day at 8:00 AM");
  assert.equal(f.scheduleText({ unit: "weeks", interval: 1, weekdays: [2], minuteOfDay: 510 }), "Every Monday at 8:30 AM");
  assert.equal(f.scheduleText({ unit: "weeks", interval: 2, weekdays: [1], minuteOfDay: 600 }), "Every 2 weeks on Sunday at 10:00 AM");
  assert.equal(f.scheduleText({ unit: "weeks", interval: 1, weekdays: [6, 2, 4], minuteOfDay: 900 }), "Every Monday, Wednesday and Friday at 3:00 PM");
  assert.equal(f.scheduleText({ unit: "days", interval: 1, minuteOfDay: 1170 }), "Every day at 7:30 PM");
  assert.equal(f.scheduleText({ unit: "days", interval: 3, minuteOfDay: 435 }), "Every 3 days at 7:15 AM");
});

test("tasks are grouped like the Mac: Late Penalty, Overdue, then by day, then finished", () => {
  const tasks = [
    task({ title: "Late one", status: "provenLate", statusAt: NOW - 60_000, penaltyEndsAt: NOW + 600_000, due: NOW - 3600_000 }),
    task({ title: "Overdue", due: NOW - 60_000 }),
    task({ title: "Tonight", due: at(2026, 10, 19, 21) }),
    task({ title: "Tomorrow B", due: at(2026, 10, 20, 9) }),
    task({ title: "Tomorrow A", due: at(2026, 10, 20, 9) }),
    task({ title: "Thursday", due: at(2026, 10, 22, 15) }),
    task({ title: "Done", status: "proven", statusAt: NOW - 86400_000, due: NOW - 86400_000 }),
  ];
  const sections = f.taskSections(tasks, NOW, TZ);
  assert.deepEqual(sections.map((s) => s.title), ["Late Penalty", "Overdue", "Today", "Tomorrow", "Thursday, October 22", "Finished in the last two weeks"]);
  assert.deepEqual(sections[3].tasks.map((t) => t.title), ["Tomorrow A", "Tomorrow B"]);
  assert.equal(sections[2].subtitle, "Monday, October 19");
  assert.equal(f.taskStatus(tasks[1], NOW, TZ), "Overdue since 7:59 PM");
});

test("command labels and words for parents", () => {
  const s = state({ tasks: [task({ id: "t1", title: "Essay" })], devices: [{ id: "d2", name: "Dad's Pixel" }] });
  assert.equal(f.commandLabel("lock", { until: at(2026, 10, 19, 21), strength: "all" }, s, NOW), "Lock until 9:00 PM");
  assert.equal(f.commandLabel("lock", { until: null, strength: "homework" }, s, NOW), "Lock until you unlock it");
  assert.equal(f.commandLabel("deleteTask", { id: "t1" }, s, NOW), "Delete “Essay”");
  assert.equal(f.commandLabel("removeDevice", { id: "d2" }, s, NOW), "Remove Dad's Pixel");
  assert.equal(f.commandLabel("setPenalty", { minutes: 90 }, s, NOW), "Late penalty: 1 hour 30 minutes");
  assert.equal(f.duration(0), "No penalty");
  assert.equal(f.flagTitle("gap"), "Tax Collector wasn't running");
  assert.equal(f.approvalNote("Approved by Test iPhone."), "Approved by Test iPhone.", "the computer's note, not Claude's");
  assert.equal(f.approvalNote("Approved by your guardian."), "Approved by a parent at the computer.");
  assert.equal(f.approvalNote(""), "Approved by a parent");
  assert.equal(f.approvalNote(undefined), "Approved by a parent");
  assert.equal(phone.cleanDeviceName("  Mom's\niPhone that has a very very long name indeed  "), "Mom's iPhone that has a very very long n");
  assert.ok(f.courseSlot("Math 8") >= 0 && f.courseSlot("Math 8") < 8);
  assert.equal(f.courseSlot("Math 8"), f.courseSlot("math 8"), "case doesn't matter");
});

// ---------------------------------------------------------------- the app's files

const jsFiles = () => {
  const out = [];
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) walk(join(dir, e.name));
      else if (/\.(js|mjs)$/.test(e.name)) out.push(join(dir, e.name));
    }
  };
  walk(PARENT);
  return out;
};

test("no HTML from strings: text from the computer only ever goes in as text", () => {
  for (const file of jsFiles()) {
    const src = readFileSync(file, "utf8");
    for (const banned of ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "DOMParser", "createContextualFragment", "eval(", "new Function"]) {
      assert.ok(!src.includes(banned), `${file} uses ${banned}`);
    }
  }
});

test("nothing the content security policy forbids", () => {
  const html = readFileSync(join(PARENT, "index.html"), "utf8");
  assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), "no inline scripts");
  assert.ok(!/<style/i.test(html), "no inline styles");
  assert.ok(!/\sstyle=/i.test(html), "no style attributes");
  assert.ok(!/\son[a-z]+=/i.test(html), "no inline event handlers");
  assert.ok(!/https?:\/\//.test(html.replace(/xmlns="http:\/\/www\.w3\.org\/[^"]*"/g, "")), "nothing from another origin");
  for (const file of jsFiles()) {
    const src = readFileSync(file, "utf8");
    assert.ok(!/setAttribute\(\s*["']style["']/.test(src), `${file} sets a style attribute`);
    assert.ok(!/import\s.*from\s+["']https?:/.test(src), `${file} imports from another origin`);
  }
});

test("the server's list, the service worker's list and the files agree", () => {
  const sw = readFileSync(join(PARENT, "sw.js"), "utf8");
  const precache = JSON.parse("[" + sw.match(/const PRECACHE = \[([\s\S]*?)\];/)[1].replace(/,\s*$/, "") + "]");
  assert.deepEqual([...precache].sort(), FILES.map(([url]) => url).filter((u) => u !== "/sw.js").sort());
  for (const [, file] of FILES) assert.ok(existsSync(join(PARENT, file)), `missing ${file}`);
  for (const file of jsFiles()) {
    const rel = file.slice(PARENT.length).replace(/\\/g, "/");
    assert.ok(FILES.some(([, f2]) => f2 === rel), `${rel} isn't served`);
  }
  const manifest = JSON.parse(readFileSync(join(PARENT, "manifest.webmanifest"), "utf8"));
  for (const icon of manifest.icons) assert.ok(FILES.some(([url]) => url === icon.src), `icon ${icon.src} isn't served`);
  assert.equal(manifest.display, "standalone");
});

test("fields left out read as null (§8: Swift's encoder omits nils)", () => {
  // What the Mac sends when every optional field is nil: the keys aren't there at all.
  const s = {
    v: 1, seq: 3, sentAt: NOW,
    computer: { name: "Mac", platform: "mac", app: "0.7.0", os: "macOS", timeZone: TZ, capabilities: ["lock", "tasks"] },
    access: { mode: "locked", by: "Mom's iPhone", at: at(2026, 10, 19, 19) },
    lock: { locked: true, reasons: [{ kind: "parent" }] },
    tasks: [
      { id: "t1", title: "No course", details: "", due: NOW - 60_000, created: NOW - 86400_000, status: "pending", source: "manual", checking: false,
        proofs: [{ id: "p1", at: NOW - 120_000, files: 1, note: "", reason: "" }], extensions: [{ at: NOW, hoursAsked: 2, hoursGranted: 0, reason: "", answer: "" }] },
      { id: "t2", title: "Done", details: "", due: NOW - 86400_000, created: NOW - 2 * 86400_000, status: "proven", source: "manual", checking: false, proofs: [], extensions: [] },
    ],
    repeats: [{ id: "r1", title: "Piano", details: "", unit: "weeks", interval: 1, weekdays: [2], minuteOfDay: 1080, startDate: "2026-10-19", schedule: "Every Monday at 6:00 PM" }],
    apps: { builtIn: [], allowed: [], blocked: [], running: [], recent: [{ id: "x", name: "X" }] },
    settings: { penaltyMinutes: 30, extensionsEnabled: true },
    trackRecord: { onTime: 0, late: 0, missed: 0, extensionsThisWeek: 0 },
    activity: [], results: [{ dev: "d", n: 1, id: "c", type: "lock", outcome: "applied", reason: "", at: NOW }], devices: [], flags: [],
  };
  const summary = f.statusSummary(s, NOW);
  assert.equal(summary.headline, "Locked by Mom's iPhone until someone unlocks it", "no until means until lifted");
  assert.match(summary.detail, /homework apps allowed/);
  const sections = f.taskSections(s.tasks, NOW, TZ);
  assert.deepEqual(sections.map((x) => x.kind), ["overdue", "done"]);
  assert.equal(f.taskStatus(s.tasks[1], NOW, TZ), "Done on time", "no statusAt");
  assert.equal(f.proofVerdict(s.tasks[0].proofs[0]), "Waiting for Claude", "no verdict yet");
  assert.equal(f.commandLabel("lock", { until: null, strength: "all" }, s, NOW), "Lock until you unlock it");
  assert.equal(phone.resultFor(s, "d", "c").outcome, "applied");
  const free = f.statusSummary({ ...s, access: { mode: "free", until: at(2026, 10, 19, 22), at: 0 }, lock: { locked: false, reasons: [] } }, NOW);
  assert.equal(free.headline, "Unlocked until 10:00 PM", "no by");
  assert.equal(f.statusSummary({ ...s, access: { mode: "normal", at: 0 }, lock: { locked: false, reasons: [] }, tasks: [] }, NOW).headline, "Not locked");
});

test("freshness ages with time on the phone: an old answer never keeps saying Connected", () => {
  const t = 1_800_000_000_000;
  const live = { serverTime: t, computerSeen: t - 2_000, computerAwake: true };
  // Just answered: connected.
  assert.equal(f.freshness(live, TZ, f.serverNow(live, 5_000, 5_000)).tone, "ok");
  // The same answer, read 3 days later (a cached launch, or polls that stopped): not connected.
  const later = f.freshness(live, TZ, f.serverNow(live, 5_000, 5_000 + 3 * 86_400_000));
  assert.equal(later.tone, "silent");
  // "Now" moves on from the server's last answer, not from the phone's own clock.
  assert.equal(f.serverNow(live, 1_000, 61_000), t + 60_000);
  assert.equal(f.serverNow(null, 0, 42), 42);
});

test("dates work in languages that don't write Latin digits", () => {
  f.setLocale("ar-EG");
  try {
    const due = f.wallTime(2026, 10, 20, 8 * 60, TZ);
    assert.equal(due, at(2026, 10, 20, 8));
    assert.deepEqual(f.zoned(due, TZ), { y: 2026, m: 10, d: 20, weekday: 3, minute: 480 });
    assert.equal(f.dayKey(due, TZ), "2026-10-20");
    assert.equal(f.dayOffset(due, NOW, TZ), 1);
    assert.equal(f.nextClockTime("21:00", NOW, TZ), at(2026, 10, 19, 21));
    const sections = f.taskSections([task({ title: "A", due: at(2026, 10, 20, 8) }), task({ title: "B", due: at(2026, 10, 22, 8) })], NOW, TZ);
    assert.equal(sections.length, 2, "one section per day");
    assert.equal(sections[0].title, "Tomorrow");
    assert.match(f.time(due, TZ), /[٠-٩]/, "what's shown is still in the phone's language");
  } finally {
    f.setLocale("en-US");
  }
});

test("a send whose answer was lost: 'Couldn't confirm it was sent', and the computer's result wins", () => {
  const dev = "6f1c0e3a-2b4d-4c8e-9a1f-0d2e3c4b5a69";
  const live = { serverTime: 1000, computerSeen: 1000, computerAwake: true, instance: "A" };
  const lost = { id: "c9", seq: null, error: "Can't reach the server.", box: "sealed" };
  const ctx = (extra) => ({ deviceId: dev, state: null, meta: { ackedUpTo: 0 }, live, ...extra });
  assert.equal(f.phaseLabel(phone.commandPhase(lost, ctx()), live).text, "Couldn't confirm it was sent");
  assert.ok(!f.isFinal(phone.commandPhase(lost, ctx()).phase), "kept open, so it can still be matched");
  const state = { results: [{ dev, n: 1, id: "c9", type: "lock", outcome: "applied", reason: "", at: 1 }] };
  assert.equal(phone.commandPhase(lost, ctx({ state })).phase, "applied");
  // Without the box there's nothing to resend: an ordinary failure.
  assert.equal(phone.commandPhase({ ...lost, box: null }, ctx()).phase, "failed");
  assert.ok(phone.maybeSent({ code: "network" }) && phone.maybeSent({ code: "server", status: 500 }));
  assert.ok(!phone.maybeSent({ code: "unauthorized", status: 401 }) && !phone.maybeSent({ code: "server", status: 404 }));
});

test("a command the server took before losing its data is shown as lost, never as delivered", () => {
  const dev = "6f1c0e3a-2b4d-4c8e-9a1f-0d2e3c4b5a69";
  const cmd = { id: "c1", seq: 57, instance: "A" };
  const same = { serverTime: 1, computerSeen: 1, computerAwake: true, instance: "A" };
  const reset = { ...same, instance: "B" };
  assert.equal(phone.commandPhase(cmd, { deviceId: dev, meta: { ackedUpTo: 57 }, live: same }).phase, "delivered");
  const after = phone.commandPhase(cmd, { deviceId: dev, meta: { ackedUpTo: 60 }, live: reset });
  assert.equal(after.phase, "lost");
  assert.equal(f.phaseLabel(after, reset).text, "Lost when the server was reset");
  assert.ok(f.isFinal("lost"));
});

test("counter catch-up ignores a 'last' that can't be a time", async () => {
  const counters = new Map([["x", 10]]);
  const store = { getCounter: async (id) => counters.get(id), setCounter: async (id, n) => counters.set(id, n) };
  const now = () => 1_800_000_000_000;
  const computer = { id: "x", deviceId: "d" };
  assert.equal(await phone.catchUpCounter({ results: [{ dev: "d", reason: "replayed", last: 2 ** 53 + 10 }] }, computer, store, now), false);
  assert.equal(await phone.catchUpCounter({ results: [{ dev: "d", reason: "replayed", last: now() + 2 * 86_400_000 }] }, computer, store, now), false);
  assert.equal(counters.get("x"), 10);
  assert.equal(await phone.catchUpCounter({ results: [{ dev: "d", reason: "replayed", last: now() - 5 }] }, computer, store, now), true);
  assert.equal(counters.get("x"), now() - 5);
});
