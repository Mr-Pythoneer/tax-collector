// Message the student, Activity, and Phones (remove one, or unpair this one).
import { h, screen, group, row, buttonRow, empty, confirm, note } from "../ui.js";
import * as f from "../format.js";
import * as phone from "../phone.js";
import { nowOf, zone, backTo, problemNotes, waiting, commandRows } from "./common.js";

const MAX = 300;

export function renderMessage({ app, view }) {
  if (!view.state) return { el: waiting(view, "Message", app), live: true };
  const tz = zone(view);
  const text = h("textarea", { maxlength: MAX, rows: 5, placeholder: "Like “Dinner at 7. Finish the worksheet first.”" });
  const count = h("span", { class: "counter", text: `0 / ${MAX}` });
  const currentBox = h("div");
  const sentBox = h("div");
  text.addEventListener("input", () => (count.textContent = `${[...text.value].length} / ${MAX}`));

  const drawCurrent = () => {
    const m = typeof view.state.message === "string" ? { text: view.state.message } : view.state.message;
    const now = nowOf(view);
    currentBox.replaceChildren(m?.text ? group({ header: "Showing on the computer now" },
      row({ title: m.text, subtitle: [m.by && "From " + f.byWords(m.by), m.at && f.when(m.at, now, tz)].filter(Boolean).join(", ") })) : "");
    const rows = commandRows(view, { types: ["message"], limit: 3 });
    sentBox.replaceChildren(rows.length ? group({ header: "Sent from this phone" }, rows) : "");
  };
  drawCurrent();

  const sendIt = () => {
    const value = text.value.replace(/\s+/g, " ").trim();
    if (!value) return;
    app.send(view, "message", { text: [...value].slice(0, MAX).join("") });
    text.value = "";
    count.textContent = `0 / ${MAX}`;
    text.blur();
  };

  const el = screen({ title: "Message", back: backTo(view), action: { label: "Send", bold: true, onClick: sendIt } },
    problemNotes(view, app),
    group({ footer: "It pops up as a notification on the computer and stays on its main window and lock screen for 24 hours. A new message replaces the old one." },
      h("div", { class: "row input-row" }, text),
      h("div", { class: "row counter-row" }, count)),
    sentBox,
    currentBox);
  return { el, live: false, update: drawCurrent };
}

export function renderActivity({ app, view }) {
  if (!view.state) return { el: waiting(view, "Activity", app), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const events = [...(view.state.activity ?? [])].sort((a, b) => b.at - a.at);
  const days = new Map();
  for (const e of events) {
    const key = f.dayKey(e.at, tz);
    if (!days.has(key)) days.set(key, []);
    days.get(key).push(e);
  }
  const el = screen({ title: "Activity", back: backTo(view) },
    problemNotes(view, app),
    events.length
      ? [...days.values()].map((list) => group({ header: f.dayName(list[0].at, now, tz) },
        list.map((e) => row({ title: e.text, value: f.time(e.at, tz), className: "activity-row" }))))
      : empty("Nothing yet", "What happens on the computer shows up here: proofs, Claude's answers, locks and what parents did."),
    events.length > 0 && h("p", { class: "page-footer", text: "The latest 100 events, as the computer recorded them." }));
  return { el, live: true };
}

export function renderDevices({ app, view }) {
  if (!view.state) return { el: waiting(view, "Phones", app), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const mine = view.rec.deviceId;
  const devices = [...(view.state.devices ?? [])].sort((a, b) => a.pairedAt - b.pairedAt);

  const removeOther = async (d) => {
    const ok = await confirm({ title: `Remove ${d.name}?`, message: "That phone stops seeing or controlling this computer straight away. It would need a new code to pair again.", ok: "Remove Phone" });
    if (ok) app.send(view, "removeDevice", { id: d.id });
  };

  const unpair = async () => {
    const ok = await confirm({ title: "Unpair this phone?", message: `It stops seeing ${view.rec.computerName}, and its keys are deleted here. You'd need a new code to pair again.`, ok: "Unpair" });
    if (!ok) return;
    const cmd = await app.send(view, "removeDevice", { id: mine });
    if (cmd.phase === "failed" && cmd.error && !/connected|unlinked/.test(cmd.error)) {
      const anyway = await confirm({ title: "Couldn't reach the computer", message: "Forget it on this phone anyway? The computer will still list this phone until someone removes it there.", ok: "Forget on This Phone" });
      if (!anyway) return;
    }
    await app.forget(view.rec.id);
    app.replace("/");
  };

  const el = screen({ title: "Phones", back: backTo(view) },
    problemNotes(view, app),
    group({ header: "Paired with " + view.rec.computerName, footer: "Removing a phone is a real cut-off: the computer drops its key and the server forgets it. If a phone is lost, remove it here from the other parent's phone." },
      devices.length ? devices.map((d) => row({
        title: d.id === mine ? `${d.name} (this phone)` : d.name,
        subtitle: d.pairedAt ? "Paired " + f.when(d.pairedAt, now, tz) : "",
        onClick: d.id === mine ? undefined : () => removeOther(d),
        accessory: d.id === mine ? null : h("span", { class: "row-button tone-destructive", text: "Remove" }),
      })) : row({ title: "No phones listed", className: "muted-row" })),
    commandRows(view, { types: ["removeDevice"], limit: 2 }).length > 0 && group({ header: "Sent from this phone" }, commandRows(view, { types: ["removeDevice"], limit: 2 })),
    group({ header: "This phone" },
      row({ title: "Name", value: view.rec.deviceName }),
      row({ title: "Server", value: new URL(view.rec.origin).host }),
      row({ title: "Paired", value: f.when(view.rec.pairedAt, Date.now(), undefined) })),
    group({}, buttonRow({ text: "Unpair This Phone", tone: "destructive", onClick: unpair })),
    phone.isDeviceId(mine) ? null : note("This phone's pairing looks damaged. Unpair it and pair again.", "bad"));
  return { el, live: true };
}
