// Lock or unlock: lock now (until a time or until lifted, homework apps or everything),
// unlock until a time, or go back to the normal rules. Every time sent is absolute.
import { h, screen, group, row, buttonRow, segmented, fieldRow, confirm, checkmark } from "../ui.js";
import * as f from "../format.js";
import { nowOf, zone, backTo, problemNotes, commandRows, waiting } from "./common.js";

const MINUTE = 60_000;

/** A list of choices with a checkmark, like iOS Settings. Returns { el, value(), refresh() }. */
function choices(options, initial, onPick) {
  let current = initial;
  const rows = [];
  const draw = () => rows.forEach(({ el, o }) => {
    el.classList.toggle("selected", o.value === current);
    el.setAttribute("aria-pressed", String(o.value === current));
    const label = typeof o.label === "function" ? o.label() : o.label;
    el.querySelector(".row-title").textContent = label.title;
    el.querySelector(".row-value").textContent = label.value ?? "";
  });
  for (const o of options) {
    const el = row({ title: "", value: " ", onClick: () => ((current = o.value), draw(), onPick?.(o.value)), className: "choice-row" });
    el.append(checkmark());
    rows.push({ el, o });
  }
  draw();
  return { els: rows.map((r) => r.el), value: () => current, refresh: draw };
}

export function render({ app, view }) {
  if (!view.state) return { el: waiting(view, "Lock or Unlock", app), live: true };
  const tz = zone(view);
  const now = () => nowOf(view);
  const at = (minutes) => () => ({ title: minutes < 60 ? `For ${minutes} minutes` : minutes === 60 ? "For 1 hour" : `For ${minutes / 60} hours`, value: "until " + f.time(Math.ceil((now() + minutes * MINUTE) / MINUTE) * MINUTE, tz) });

  const statusBox = h("div", { class: "status-card compact" });
  const drawStatus = () => {
    const s = f.statusSummary(view.state, now());
    statusBox.className = "status-card compact tone-" + s.tone;
    statusBox.replaceChildren(h("p", { class: "status-headline", text: s.headline }), s.detail ? h("p", { class: "status-detail", text: s.detail }) : "");
  };
  drawStatus();

  // Lock now
  let strength = "homework";
  const lockTime = h("input", { type: "time", value: defaultTime(now(), tz, 21) });
  const lockTimeRow = fieldRow({ label: "Time", input: lockTime });
  const lockUntil = choices([
    { value: "lifted", label: { title: "Until you unlock it" } },
    { value: 30, label: at(30) },
    { value: 60, label: at(60) },
    { value: 120, label: at(120) },
    { value: "time", label: { title: "Until a time" } },
  ], "lifted", (v) => lockTimeRow.classList.toggle("hidden", v !== "time"));
  lockTimeRow.classList.add("hidden");
  const lockNote = h("input", { type: "text", maxlength: 300, placeholder: "Optional" });

  const untilFrom = (choice, input) => {
    if (choice === "lifted") return null;
    if (choice === "time") return f.nextClockTime(input.value, now(), tz);
    return Math.ceil((now() + choice * MINUTE) / MINUTE) * MINUTE;
  };

  const lockNow = async () => {
    const until = untilFrom(lockUntil.value(), lockTime);
    if (lockUntil.value() === "time" && !until) return;
    const words = until ? `until ${f.when(until, now(), tz)}` : "until you unlock it";
    const ok = await confirm({
      title: `Lock ${view.rec.computerName} ${words}?`,
      message: strength === "all" ? "Every app closes except system apps and Tax Collector." : "Only homework apps stay open.",
      ok: "Lock Now",
    });
    if (!ok) return;
    const args = { until, strength };
    const noteText = lockNote.value.trim();
    if (noteText) args.note = noteText.slice(0, 300);
    app.send(view, "lock", args);
  };

  // Unlock for a while
  const freeTime = h("input", { type: "time", value: defaultTime(now(), tz, 21) });
  const freeTimeRow = fieldRow({ label: "Time", input: freeTime });
  freeTimeRow.classList.add("hidden");
  const freeUntil = choices([
    { value: 30, label: at(30) },
    { value: 60, label: at(60) },
    { value: 120, label: at(120) },
    { value: "time", label: { title: "Until a time" } },
  ], 60, (v) => freeTimeRow.classList.toggle("hidden", v !== "time"));

  const unlock = async () => {
    const until = untilFrom(freeUntil.value(), freeTime);
    if (!until) return;
    const ok = await confirm({ title: `Unlock ${view.rec.computerName} until ${f.when(until, now(), tz)}?`, message: "Overdue work won't lock it until then.", ok: "Unlock", tone: "tint" });
    if (ok) app.send(view, "free", { until });
  };

  const normalGroup = h("div");
  const drawNormal = () => {
    const mode = view.state.access?.mode;
    normalGroup.replaceChildren(mode && mode !== "normal" ? group({ footer: "Clears a lock or unlock from a parent. Overdue work locks the computer again." },
      buttonRow({ text: "Back to Normal Rules", onClick: () => app.send(view, "normal", {}) })) : "");
  };
  drawNormal();

  const commandsBox = h("div");
  const drawCommands = () => {
    const rows = commandRows(view, { types: ["lock", "free", "normal"], limit: 3 });
    commandsBox.replaceChildren(rows.length ? group({ header: "Sent from this phone" }, rows) : "");
  };
  drawCommands();

  const el = screen({ title: "Lock or Unlock", back: backTo(view) },
    problemNotes(view, app),
    group({ className: "status-group" }, statusBox),
    commandsBox,
    group({ header: "Lock now", footer: "Homework apps: the apps allowed during locks stay open. Everything: all apps close except system apps and Tax Collector. Websites can't be blocked." },
      h("div", { class: "row segmented-row" }, segmented({ label: "What stays open", options: [{ value: "homework", label: "Homework apps" }, { value: "all", label: "Everything closed" }], value: strength, onChange: (v) => (strength = v) })),
      lockUntil.els,
      lockTimeRow,
      fieldRow({ label: "Note", input: lockNote }),
      buttonRow({ text: "Lock Now", tone: "destructive", onClick: lockNow, bold: true })),
    group({ header: "Unlock for a while", footer: "Like the guardian's “unlock for a while” on the computer: overdue work won't lock it until then." },
      freeUntil.els,
      freeTimeRow,
      buttonRow({ text: "Unlock", onClick: unlock, bold: true })),
    normalGroup);

  // Keep the times and status fresh without redrawing the form.
  const timer = setInterval(() => (lockUntil.refresh(), freeUntil.refresh()), 15_000);
  return {
    el,
    live: false,
    update: () => (drawStatus(), drawNormal(), drawCommands()),
    cleanup: () => clearInterval(timer),
  };
}

/** "21:00", or the next whole hour if that's already past. */
function defaultTime(now, tz, hour) {
  const z = f.zoned(now, tz);
  const h = z.minute < hour * 60 - 30 ? hour : Math.min(23, Math.floor(z.minute / 60) + 2);
  return String(h).padStart(2, "0") + ":00";
}
