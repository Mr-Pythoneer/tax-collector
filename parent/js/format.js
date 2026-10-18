// Words and times for the parent app. Pure functions, so they're tested in Node too.
// Times show in the computer's time zone: due dates and locks belong to the student's day.

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

let LOCALE; // the phone's own; tests set "en-US"
export const setLocale = (locale) => void (LOCALE = locale);

const formats = new Map();
function fmt(tz, options, locale = LOCALE) {
  const key = (locale ?? "") + "|" + (tz ?? "") + "|" + JSON.stringify(options);
  let f = formats.get(key);
  if (!f) {
    try {
      f = new Intl.DateTimeFormat(locale, { ...options, timeZone: tz });
    } catch {
      f = new Intl.DateTimeFormat(locale, options);
    }
    formats.set(key, f);
  }
  return f;
}

// Parts are read back as numbers, so they're always formatted with Latin digits and English
// names; only what's shown uses the phone's own language (which may write ٢٠٢٦, say).
const PARSE_LOCALE = "en-US-u-nu-latn";

/** A usable IANA zone, or undefined for the phone's own. */
export function zoneOf(state) {
  const tz = state?.computer?.timeZone;
  if (typeof tz !== "string" || !tz) return undefined;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return undefined;
  }
}

const WEEKDAY = { Sun: 1, Mon: 2, Tue: 3, Wed: 4, Thu: 5, Fri: 6, Sat: 7 };

/** Calendar parts of `ms` in `tz`: { y, m, d, weekday (1 = Sunday), minute (of the day) }. */
export function zoned(ms, tz) {
  const parts = {};
  for (const p of fmt(tz, { year: "numeric", month: "2-digit", day: "2-digit", weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }, PARSE_LOCALE).formatToParts(ms)) {
    parts[p.type] = p.value;
  }
  // formatToParts in the phone's locale may not use English weekday names: work it out from the date.
  const y = +parts.year, m = +parts.month, d = +parts.day;
  const weekday = WEEKDAY[parts.weekday] ?? new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 1;
  return { y, m, d, weekday, minute: (+parts.hour % 24) * 60 + +parts.minute };
}

/** Milliseconds for a wall-clock time in `tz`, good across daylight-saving changes. */
export function wallTime(y, m, d, minuteOfDay, tz) {
  let guess = Date.UTC(y, m - 1, d, Math.floor(minuteOfDay / 60), minuteOfDay % 60);
  for (let i = 0; i < 3; i++) {
    const z = zoned(guess, tz);
    const want = Date.UTC(y, m - 1, d) / MINUTE + minuteOfDay;
    const got = Date.UTC(z.y, z.m - 1, z.d) / MINUTE + z.minute;
    if (want === got) break;
    guess += (want - got) * MINUTE;
  }
  return guess;
}

/** The next time the clock in `tz` shows "hh:mm": today, or tomorrow if that's past. */
export function nextClockTime(value, now, tz) {
  const [hh, mm] = String(value).split(":").map(Number);
  if (!Number.isInteger(hh) || !Number.isInteger(mm)) return null;
  const z = zoned(now, tz);
  let t = wallTime(z.y, z.m, z.d, hh * 60 + mm, tz);
  if (t <= now + MINUTE) {
    const d = new Date(Date.UTC(z.y, z.m - 1, z.d + 1));
    t = wallTime(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), hh * 60 + mm, tz);
  }
  return t;
}

export const dayKey = (ms, tz) => {
  const z = zoned(ms, tz);
  return `${z.y}-${String(z.m).padStart(2, "0")}-${String(z.d).padStart(2, "0")}`;
};

/** Days from `now`'s day to `ms`'s day, in `tz`: 0 today, 1 tomorrow, -1 yesterday. */
export function dayOffset(ms, now, tz) {
  const a = zoned(ms, tz);
  const b = zoned(now, tz);
  return Math.round((Date.UTC(a.y, a.m - 1, a.d) - Date.UTC(b.y, b.m - 1, b.d)) / DAY);
}

export const time = (ms, tz) => fmt(tz, { hour: "numeric", minute: "2-digit" }).format(ms);
export const longDate = (ms, tz) => fmt(tz, { weekday: "long", month: "long", day: "numeric" }).format(ms);
export const shortDate = (ms, tz) => fmt(tz, { weekday: "short", month: "short", day: "numeric" }).format(ms);

/** "Today", "Tomorrow", "Yesterday", or "Monday, October 19". */
export function dayName(ms, now, tz) {
  const off = dayOffset(ms, now, tz);
  if (off === 0) return "Today";
  if (off === 1) return "Tomorrow";
  if (off === -1) return "Yesterday";
  return longDate(ms, tz);
}

/** "7:02 PM", "tomorrow 8:00 AM", "yesterday 9:00 PM", "Mon, Oct 19, 7:02 PM". */
export function when(ms, now, tz) {
  const off = dayOffset(ms, now, tz);
  if (off === 0) return time(ms, tz);
  if (off === 1) return "tomorrow " + time(ms, tz);
  if (off === -1) return "yesterday " + time(ms, tz);
  return shortDate(ms, tz) + ", " + time(ms, tz);
}

/** "just now", "5 minutes ago", "3 hours ago", "2 days ago". */
export function ago(ms) {
  if (ms < 45_000) return "just now";
  if (ms < 90_000) return "a minute ago";
  if (ms < HOUR) return `${Math.round(ms / MINUTE)} minutes ago`;
  if (ms < 1.5 * HOUR) return "an hour ago";
  if (ms < DAY) return `${Math.round(ms / HOUR)} hours ago`;
  if (ms < 1.5 * DAY) return "a day ago";
  return `${Math.round(ms / DAY)} days ago`;
}

/** "No penalty", "15 minutes", "1 hour", "1 hour 30 minutes". */
export function duration(minutes) {
  if (!minutes) return "No penalty";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  const parts = [];
  if (h) parts.push(h === 1 ? "1 hour" : `${h} hours`);
  if (m) parts.push(m === 1 ? "1 minute" : `${m} minutes`);
  return parts.join(" ");
}

const plural = (n, one, many = one + "s") => `${n} ${n === 1 ? one : many}`;

// ---------------------------------------------------------------- repeats

const DAY_NAMES = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
export const DAY_LETTERS = ["", "S", "M", "T", "W", "T", "F", "S"];

function list(names) {
  return names.length <= 2 ? names.join(" and ") : names.slice(0, -1).join(", ") + " and " + names.at(-1);
}

/** The same words the Mac uses: "Every weekday at 6:00 PM", "Every 2 weeks on Sunday at 10:00 AM". */
export function scheduleText({ unit, interval, weekdays = [], minuteOfDay }) {
  const at = fmt("UTC", { hour: "numeric", minute: "2-digit" }).format(Date.UTC(2000, 0, 1, 0, minuteOfDay));
  if (unit === "days") return interval === 1 ? `Every day at ${at}` : `Every ${interval} days at ${at}`;
  const set = [...new Set(weekdays)].sort((a, b) => a - b);
  const everyDay = set.length === 7;
  const weekdaysOnly = set.join() === "2,3,4,5,6";
  if (!set.length) return `Every ${interval === 1 ? "week" : interval + " weeks"} at ${at}`;
  if (interval === 1) return everyDay ? `Every day at ${at}` : weekdaysOnly ? `Every weekday at ${at}` : `Every ${list(set.map((w) => DAY_NAMES[w]))} at ${at}`;
  return `Every ${interval} weeks on ${everyDay ? "every day" : weekdaysOnly ? "weekdays" : list(set.map((w) => DAY_NAMES[w]))} at ${at}`;
}

// ---------------------------------------------------------------- tasks

/**
 * A color slot per course name, the same on every launch. (The Mac colors by the full class
 * name, which the state doesn't carry, so the phone picks its own: FNV-1a, then mixed and read
 * from the top bits, since the low bits of a plain string hash repeat too often for 8 colors.)
 */
export function courseSlot(course, slots = 8) {
  let h = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(String(course).toLowerCase())) h = Math.imul(h ^ byte, 0x01000193);
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return Math.floor(((h >>> 0) / 2 ** 32) * slots);
}

export function proofVerdict(p) {
  switch (p?.verdict) {
    case "accepted": return "Accepted by Claude";
    case "rejected": return "Not accepted by Claude";
    case "error": return "Claude couldn't check it";
    case "guardianApproved": return "Approved by a parent";
    default: return "Waiting for Claude";
  }
}

/**
 * For a parent-approved proof, `reason` is the computer's own note ("Approved by Mom's iPhone."),
 * not Claude's. The Mac names its guardian "your guardian", worded for the student.
 */
export function approvalNote(reason) {
  const note = String(reason ?? "").trim();
  if (!note) return "Approved by a parent";
  if (/^approved by your guardian\.?$/i.test(note)) return "Approved by a parent at the computer.";
  return note;
}

export function taskStatus(t, now, tz) {
  switch (t.status) {
    case "proven": return "Done on time" + (t.statusAt ? ", " + when(t.statusAt, now, tz) : "");
    case "provenLate": return "Done late" + (t.statusAt ? ", " + when(t.statusAt, now, tz) : "");
    case "excused": return "Excused";
    default:
      if (t.checking) return "Claude is checking a proof";
      if (t.due <= now) return "Overdue since " + when(t.due, now, tz);
      return "Due " + when(t.due, now, tz);
  }
}

/** Sections like the Mac's main window: Late Penalty, Overdue, then one per day; then recently finished. */
export function taskSections(tasks, now, tz) {
  const byDue = (a, b) => a.due - b.due || String(a.title).localeCompare(String(b.title));
  const sections = [];
  const penalty = tasks.filter((t) => t.status === "provenLate" && t.penaltyEndsAt > now).sort(byDue);
  if (penalty.length) sections.push({ kind: "penalty", title: "Late Penalty", tasks: penalty });
  const pending = tasks.filter((t) => t.status === "pending").sort(byDue);
  const overdue = pending.filter((t) => t.due <= now);
  if (overdue.length) sections.push({ kind: "overdue", title: "Overdue", tasks: overdue });
  const days = new Map();
  for (const t of pending) {
    if (t.due <= now) continue;
    const key = dayKey(t.due, tz);
    if (!days.has(key)) days.set(key, []);
    days.get(key).push(t);
  }
  for (const [, list] of days) {
    const off = dayOffset(list[0].due, now, tz);
    const name = off === 0 ? "Today" : off === 1 ? "Tomorrow" : null;
    sections.push({ kind: "day", title: name ?? longDate(list[0].due, tz), subtitle: name ? longDate(list[0].due, tz) : "", tasks: list });
  }
  const done = tasks.filter((t) => t.status !== "pending" && !penalty.includes(t)).sort((a, b) => (b.statusAt ?? b.due) - (a.statusAt ?? a.due));
  if (done.length) sections.push({ kind: "done", title: "Finished in the last two weeks", tasks: done });
  return sections;
}

// ---------------------------------------------------------------- status

const strengthWords = (s) => (s === "all" ? "everything closed" : "homework apps allowed");

/** Who changed access, for a parent: the Mac words guardian actions for the student ("your guardian"). */
export const byWords = (by) => (!by ? "a parent" : /^your guardian$/i.test(by) ? "a parent at the computer" : by);

/**
 * The plain-words status: { tone: "locked" | "free" | "ok", headline, detail }.
 * "Locked since 7:02 PM: Math worksheet overdue".
 */
export function statusSummary(state, now) {
  const tz = zoneOf(state);
  const a = state.access ?? {};
  const reasons = state.lock?.reasons ?? [];
  const parent = reasons.find((r) => r.kind === "parent");
  const overdue = reasons.filter((r) => r.kind === "overdue");
  const penalties = reasons.filter((r) => r.kind === "penalty");
  const tasks = state.tasks ?? [];
  const byId = new Map(tasks.map((t) => [t.id, t]));

  if (a.mode === "locked" || parent) {
    const by = byWords(a.by || parent?.title);
    const until = a.until ?? parent?.until ?? null;
    const since = a.at ? `since ${when(a.at, now, tz)} ` : "";
    return {
      tone: "locked",
      headline: until ? `Locked by ${by} until ${when(until, now, tz)}` : `Locked by ${by} until someone unlocks it`,
      detail: `${since ? "Locked " + since.trim() + ", " : ""}${strengthWords(a.strength)}.`,
    };
  }
  if (state.lock?.locked && overdue.length) {
    const first = overdue.map((r) => byId.get(r.taskId)).filter(Boolean).sort((x, y) => x.due - y.due)[0];
    const name = first?.title ?? overdue[0].title ?? "A task";
    const since = first ? `Locked since ${when(first.due, now, tz)}: ` : "Locked: ";
    const more = overdue.length > 1 ? ` and ${plural(overdue.length - 1, "more")}` : "";
    return { tone: "locked", headline: `${since}${name}${more} overdue`, detail: "It unlocks when the work is turned in and Claude accepts the proof, or when you approve it." };
  }
  if (state.lock?.locked && penalties.length) {
    const p = penalties.sort((x, y) => (y.until ?? 0) - (x.until ?? 0))[0];
    return { tone: "locked", headline: `Locked until ${p.until ? when(p.until, now, tz) : "the penalty ends"}: late penalty for ${p.title ?? "a late task"}`, detail: "The work was turned in late, so the computer stays locked for the penalty time." };
  }
  if (state.lock?.locked) return { tone: "locked", headline: "Locked", detail: "" };
  if (a.mode === "free" && a.until) {
    const by = a.by ? byWords(a.by) : "";
    return { tone: "free", headline: `Unlocked until ${when(a.until, now, tz)}`, detail: `${by ? "By " + by + ". " : ""}Overdue work won't lock the computer until then.` };
  }
  const next = tasks.filter((t) => t.status === "pending" && t.due > now).sort((x, y) => x.due - y.due)[0];
  return { tone: "ok", headline: "Not locked", detail: next ? `Next: ${next.title}, due ${when(next.due, now, tz)}.` : "Nothing is due." };
}

/**
 * The server's clock now, as best the phone can tell: its last answer's time plus how long ago
 * that answer came. Freshness and "now" are judged on it, never on the phone's own clock.
 */
export function serverNow(live, receivedAt, phoneNow = Date.now()) {
  if (live?.serverTime == null || !receivedAt) return live?.serverTime ?? phoneNow;
  return live.serverTime + Math.max(0, phoneNow - receivedAt);
}

/**
 * How fresh the news is, from the server's clock only: (server now) − computerSeen.
 * `now` is serverNow(...); it defaults to the answer's own time.
 * { tone: "ok" | "asleep" | "late" | "silent" | "unknown", text }.
 */
export function freshness(live, tz, now = live?.serverTime) {
  if (!live || live.serverTime == null || live.computerSeen == null) return { tone: "unknown", text: "Waiting for the computer" };
  if (!live.computerSeen) return { tone: "silent", text: "The computer hasn't connected yet" };
  const gap = Math.max(0, now - live.computerSeen);
  const at = when(live.computerSeen, now, tz);
  if (live.computerAwake === false) return { tone: "asleep", text: `Asleep since ${at}` };
  if (gap < 75_000) return { tone: "ok", text: "Connected" };
  if (gap < 15 * MINUTE) return { tone: "late", text: `Last heard from ${ago(gap)}` };
  return { tone: "silent", text: `No word since ${at}. The computer may be off the internet, or Tax Collector isn't running.` };
}

// ---------------------------------------------------------------- flags

const FLAG_TITLES = {
  testMode: "Test mode is on",
  noBackgroundAgent: "The background helper is missing",
  guardianChanged: "The guardian code changed",
  overrideMismatch: "The unlock time was changed by hand",
  clockSkew: "The computer's clock is off",
  gap: "Tax Collector wasn't running",
  linkRestored: "The link file was put back",
  restarts: "Tax Collector was restarted",
  badCommand: "A command failed its check",
};
export const flagTitle = (kind) => FLAG_TITLES[kind] ?? "Warning";

// ---------------------------------------------------------------- commands

const quote = (s) => `“${String(s ?? "").slice(0, 60)}”`;

/** What a command does, in a few words: "Lock until 9:00 PM". */
export function commandLabel(type, args = {}, state, now = Date.now()) {
  const tz = zoneOf(state);
  const taskTitle = (id) => (state?.tasks ?? []).find((t) => t.id === id)?.title;
  const repeatTitle = (id) => (state?.repeats ?? []).find((r) => r.id === id)?.title;
  const deviceName = (id) => (state?.devices ?? []).find((d) => d.id === id)?.name;
  switch (type) {
    case "lock": return args.until ? `Lock until ${when(args.until, now, tz)}` : "Lock until you unlock it";
    case "free": return `Unlock until ${when(args.until, now, tz)}`;
    case "normal": return "Back to the normal rules";
    case "addTask": return `Add ${quote(args.task?.title)}`;
    case "editTask": return `Change ${quote(args.title ?? taskTitle(args.id) ?? "a task")}`;
    case "deleteTask": return `Delete ${quote(taskTitle(args.id) ?? "a task")}`;
    case "excuseTask": return `Excuse ${quote(taskTitle(args.id) ?? "a task")}`;
    case "approveProof": return `Approve the proof for ${quote(taskTitle(args.taskId) ?? "a task")}`;
    case "addRepeat": return `Repeat ${quote(args.repeat?.title)}`;
    case "stopRepeat": return `Stop repeating ${quote(repeatTitle(args.id) ?? "a task")}`;
    case "allowApp": return `Allow ${args.app?.name ?? "an app"} during locks`;
    case "disallowApp": return `Stop allowing ${args.app?.name ?? "an app"}`;
    case "blockApp": return `Block ${args.app?.name ?? "an app"}`;
    case "unblockApp": return `Unblock ${args.app?.name ?? "an app"}`;
    case "setPenalty": return `Late penalty: ${duration(args.minutes).toLowerCase()}`;
    case "setExtensions": return `Asking for more time: ${args.enabled ? "on" : "off"}`;
    case "message": return "Message to the student";
    case "removeDevice": return `Remove ${deviceName(args.id) ?? "a phone"}`;
    case "allowGuardianSetup": return `Allow a new guardian code until ${when(args.until, now, tz)}`;
    default: return type;
  }
}

const REASONS = {
  replayed: "it was sent twice",
  stale: "this phone's clock is off by more than 10 minutes",
  bad_signature: "its signature didn't check out",
  bad_box: "it couldn't be opened",
  wrong_target: "it was meant for another computer",
  unknown_device: "the computer doesn't know this phone",
  bad_args: "the computer didn't understand it",
  not_found: "it isn't there any more",
};
export const reasonWords = (reason) => REASONS[reason] ?? (reason ? String(reason) : "");

/** { text, tone } for where a command is: Sending… / Delivered / Applied / Rejected (reason) / Waiting: computer asleep. */
export function phaseLabel({ phase, reason }, live) {
  switch (phase) {
    case "sending": return { text: "Sending…", tone: "pending" };
    case "failed": return { text: `Not sent: ${reason || "no connection"}`, tone: "bad" };
    case "unconfirmed": return { text: "Couldn't confirm it was sent", tone: "pending" };
    case "lost": return { text: "Lost when the server was reset", tone: "bad" };
    case "waiting": return { text: "Sent", tone: "pending" };
    case "asleep": return { text: live?.computerAwake === false ? "Waiting: computer asleep" : "Waiting: computer offline", tone: "pending" };
    case "delivered": return { text: "Delivered", tone: "pending" };
    case "applied": return { text: "Applied", tone: "good" };
    case "noop": return { text: reason ? `Nothing to change: ${reason.replace(/\.$/, "").toLowerCase()}` : "Nothing to change", tone: "good" };
    case "unsupported": return { text: "Not supported on this computer", tone: "bad" };
    case "rejected": return { text: `Rejected (${reasonWords(reason) || "no reason given"})`, tone: "bad" };
    default: return { text: phase, tone: "pending" };
  }
}

export const isFinal = (phase) => ["applied", "noop", "unsupported", "rejected", "failed", "lost"].includes(phase);
