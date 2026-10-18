// Computers: every computer this phone is paired with, and the way to pair another.
import { h, screen, group, row, buttonRow } from "../ui.js";
import * as f from "../format.js";
import { freshnessOf, nowOf } from "./common.js";

export function toneOf(view, now = Date.now()) {
  if (view.problem && ["unauthorized", "gone", "unopenable", "reset", "unknown"].includes(view.problem.kind)) return "warn";
  if (!view.state) return "gray";
  const s = f.statusSummary(view.state, now);
  return s.tone === "locked" ? "red" : s.tone === "free" ? "orange" : "green";
}

export function render({ app }) {
  const views = app.views();
  if (!views.length) return { el: welcome(app), live: false };
  const rows = views.map((v) => {
    const now = nowOf(v);
    const headline = v.problem?.short ?? v.problem?.text ?? (v.state ? f.statusSummary(v.state, now).headline : "Waiting for the first update");
    const fresh = ["unauthorized", "gone", "reset", "unknown"].includes(v.problem?.kind) ? "Not updating" : v.netError ? "Can't reach the server" : freshnessOf(v).text;
    return row({
      title: v.rec.computerName,
      subtitle: headline,
      lines: [fresh],
      dot: "dot-" + toneOf(v, now),
      href: "#/c/" + encodeURIComponent(v.rec.id),
      className: "computer-row",
    });
  });
  return {
    live: true,
    el: screen({ title: "Computers", large: true },
      group({}, rows),
      group({ footer: "Each computer shows its own pairing code in Tax Collector: Guardian Settings, then Parents' phones, then Pair a Phone." },
        row({ title: "Pair a Computer", href: "#/pair", tone: "tint", chevron: false })),
      storageNote(app)),
  };
}

function storageNote(app) {
  if (app.persisted() !== false) return null;
  return group({ footer: app.isIOS() && !app.isStandalone()
    ? "Safari may clear this app's data if you don't use it for a while. Add it to your Home Screen to keep it."
    : "This browser may clear the app's data when space runs low. If that happens, pair again." });
}

function welcome(app) {
  const ios = app.isIOS();
  const installed = app.isStandalone();
  return screen({ title: "Tax Collector", large: true },
    h("p", { class: "lead", text: "See homework, lock or unlock the computer, and manage tasks from your phone." }),
    ios && !installed && group({ header: "First, put this app on your Home Screen", footer: "On iPhone, an app on the Home Screen keeps its own data, apart from Safari. Pairing here in Safari wouldn't carry over to it." },
      row({ title: "1. Tap the Share button at the bottom of Safari." }),
      row({ title: "2. Choose Add to Home Screen, then Add." }),
      row({ title: "3. Open Tax Collector from your Home Screen and pair there." })),
    group({ header: "Pair with the student's computer", footer: "The code works once, for 10 minutes. Nobody else's phone can use it without you noticing: both screens show the same number before the computer accepts." },
      row({ title: "On the computer, open Tax Collector's Guardian Settings. Under Parents' phones, choose Pair a Phone. It shows a code." }),
      buttonRow({ text: "Pair a Computer", onClick: () => app.go("/pair"), bold: true })));
}
