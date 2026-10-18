// Status: one computer at a glance, in plain words, and the way to everything else.
import { h, screen, group, row } from "../ui.js";
import * as f from "../format.js";
import { nowOf, zone, can, problemNotes, commandRows, waiting } from "./common.js";

export function render({ app, view }) {
  if (!view.state) return { el: waiting(view, view.rec.computerName, app), live: true };
  const s = view.state;
  const now = nowOf(view);
  const tz = zone(view);
  const id = encodeURIComponent(view.rec.id);
  const summary = f.statusSummary(s, now);
  // When this phone is cut off or can't reach the server, the last answer's "Connected" would be stale news.
  const cutOff = ["unauthorized", "gone"].includes(view.problem?.kind);
  const since = view.fetchedAt ? " since " + f.when(view.fetchedAt, Date.now(), undefined) : "";
  const fresh = cutOff
    ? { tone: "silent", text: "Not updating" + since }
    : view.problem?.kind === "reset"
      ? { tone: "late", text: "Waiting for the computer to connect to the server again" }
      : view.netError
        ? { tone: "late", text: "No connection to the server" + since }
        : f.freshness(view.live, tz);
  const pending = (s.tasks ?? []).filter((t) => t.status === "pending");
  const overdue = pending.filter((t) => t.due <= now).length;
  const dueToday = pending.filter((t) => t.due > now && f.dayOffset(t.due, now, tz) === 0).length;
  const flags = s.flags ?? [];
  const message = typeof s.message === "string" ? { text: s.message } : s.message;
  const apps = s.apps ?? {};

  const statusCard = h("div", { class: ["status-card", "tone-" + summary.tone] },
    h("p", { class: "status-headline", text: summary.headline }),
    summary.detail && h("p", { class: "status-detail", text: summary.detail }),
    h("p", { class: ["status-fresh", "fresh-" + fresh.tone] },
      h("span", { class: ["dot", "dot-fresh-" + fresh.tone], attrs: { "aria-hidden": "true" } }),
      h("span", { text: fresh.text })));

  const accessValue = s.access?.mode === "locked" ? "Locked by you" : s.access?.mode === "free" ? "Unlocked" : s.lock?.locked ? "Locked" : "Normal";
  const taskValue = overdue ? `${overdue} overdue` : dueToday ? `${dueToday} due today` : pending.length ? `${pending.length} to do` : "None";

  const menu = [
    can(view, "lock") && row({ title: "Lock or Unlock", value: accessValue, href: `#/c/${id}/lock` }),
    can(view, "tasks") && row({ title: "Tasks", value: taskValue, href: `#/c/${id}/tasks` }),
    can(view, "repeats") && row({ title: "Repeating Tasks", value: String((s.repeats ?? []).length || "None"), href: `#/c/${id}/repeats` }),
    (can(view, "apps") || can(view, "block")) && row({ title: "Apps", value: (apps.blocked ?? []).length ? `${apps.blocked.length} blocked` : "", href: `#/c/${id}/apps` }),
    (can(view, "penalty") || can(view, "extensions") || can(view, "guardianSetup")) && row({ title: "Rules", value: can(view, "penalty") ? f.duration(s.settings?.penaltyMinutes ?? 0) : "", href: `#/c/${id}/settings` }),
    can(view, "message") && row({ title: "Message the Student", href: `#/c/${id}/message` }),
  ];

  const rec = s.trackRecord;
  const el = screen({ title: view.rec.computerName, large: true, back: { label: "Computers", href: "#/" } },
    problemNotes(view, app),
    group({ className: "status-group" }, statusCard),
    flags.length > 0 && group({ header: "Warnings", headerTone: "warn", footer: "These come from the computer. A warning that keeps coming back can mean someone is working around Tax Collector." },
      flags.map((fl) => row({ title: f.flagTitle(fl.kind), subtitle: fl.text, value: fl.at ? f.when(fl.at, now, tz) : "", dot: "dot-orange", className: "flag-row" }))),
    message?.text && group({ header: "Your message on the computer" },
      row({ title: message.text, subtitle: message.by ? `From ${f.byWords(message.by)}${message.at ? ", " + f.when(message.at, now, tz) : ""}. Shows for 24 hours.` : "" })),
    !cutOff && group({}, menu),
    view.commands.length > 0 && group({ header: "Sent from this phone" }, commandRows(view, { limit: 4 })),
    group({},
      row({ title: "Activity", href: `#/c/${id}/activity` }),
      row({ title: "Phones", value: String((s.devices ?? []).length), href: `#/c/${id}/devices` })),
    rec && group({ header: "Track record", footer: "On time, late and missed count every task with a deadline. Extensions are this week's requests for more time." },
      h("div", { class: "row record-row" },
        stat(rec.onTime, "On time"), stat(rec.late, "Late"), stat(rec.missed, "Missed"), stat(rec.extensionsThisWeek, "Extensions"))),
    h("p", { class: "page-footer", text: [s.computer?.os, s.computer?.app && "Tax Collector " + s.computer.app, tz && tz !== Intl.DateTimeFormat().resolvedOptions().timeZone && "Times in " + tz.replace(/_/g, " ")].filter(Boolean).join(" · ") }));
  return { el, live: true };
}

const stat = (n, label) => h("div", { class: "stat" }, h("span", { class: "stat-value", text: String(n ?? 0) }), h("span", { class: "stat-label", text: label }));
