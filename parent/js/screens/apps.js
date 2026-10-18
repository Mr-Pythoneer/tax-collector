// Apps: allowed during a lock, or always blocked. New ones are picked from the apps the
// computer has seen running.
import { h, screen, group, row, empty, sheet, confirm } from "../ui.js";
import * as f from "../format.js";
import { nowOf, can, backTo, problemNotes, waiting } from "./common.js";

const appsHref = (view) => "#/c/" + encodeURIComponent(view.rec.id) + "/apps";
const ref = (a) => ({ id: a.id, name: a.name || a.id });

function removeButton(text, onClick) {
  return h("button", { type: "button", class: "row-button tone-destructive", text, onclick: onClick });
}

export function renderList({ app, view }) {
  if (!view.state) return { el: waiting(view, "Apps", app), live: true };
  const apps = view.state.apps ?? {};
  const blocked = apps.blocked ?? [];
  const allowed = apps.allowed ?? [];
  const builtIn = apps.builtIn ?? [];
  const pickHref = appsHref(view) + "/add";

  const unblock = async (a) => {
    if (await confirm({ title: `Unblock ${a.name}?`, message: "It can open again, except during a lock.", ok: "Unblock", tone: "tint" })) app.send(view, "unblockApp", { app: ref(a) });
  };
  const disallow = async (a) => {
    if (await confirm({ title: `Stop allowing ${a.name} during locks?`, ok: "Stop Allowing" })) app.send(view, "disallowApp", { app: ref(a) });
  };

  const el = screen({ title: "Apps", back: backTo(view) },
    problemNotes(view, app),
    can(view, "block") && group({ header: "Always blocked", footer: "Closed whenever they open, locked or not. Blocking beats allowing." },
      blocked.map((a) => row({ title: a.name, accessory: removeButton("Unblock", () => unblock(a)) })),
      row({ title: "Block an App…", href: pickHref, tone: "tint", chevron: false })),
    can(view, "apps") && group({ header: "Also allowed during locks", footer: "These stay open during a homework lock, along with the apps below. When you lock with everything closed, only system apps and Tax Collector stay open." },
      allowed.map((a) => row({ title: a.name, accessory: removeButton("Remove", () => disallow(a)) })),
      row({ title: "Allow an App…", href: pickHref, tone: "tint", chevron: false })),
    builtIn.length > 0 && group({ header: "Always allowed during homework locks", footer: "Tax Collector allows these by itself. Websites can't be blocked: the browser stays open during a lock." },
      builtIn.map((a) => row({ title: a.name }))));
  return { el, live: true };
}

export function renderPicker({ app, view }) {
  if (!view.state) return { el: waiting(view, "Choose an App", app), live: true };
  const now = nowOf(view);
  const apps = view.state.apps ?? {};
  const has = (list, a) => (list ?? []).some((x) => x.id === a.id);
  const statusOf = (a) => (has(apps.blocked, a) ? "Blocked" : has(apps.allowed, a) ? "Allowed" : has(apps.builtIn, a) ? "Always allowed" : "");

  const choose = async (a) => {
    const actions = [];
    if (can(view, "apps") && !has(apps.allowed, a) && !has(apps.builtIn, a)) actions.push({ text: "Allow During Locks", value: "allowApp", tone: "tint" });
    if (can(view, "apps") && has(apps.allowed, a)) actions.push({ text: "Stop Allowing", value: "disallowApp" });
    if (can(view, "block") && !has(apps.blocked, a)) actions.push({ text: "Always Block", value: "blockApp", tone: "destructive" });
    if (can(view, "block") && has(apps.blocked, a)) actions.push({ text: "Unblock", value: "unblockApp" });
    if (!actions.length) return;
    const type = await sheet({ title: a.name, message: statusOf(a) ? `Now: ${statusOf(a).toLowerCase()}.` : "", actions });
    if (!type) return;
    app.send(view, type, { app: ref(a) });
    app.back(appsHref(view).slice(1));
  };

  const running = apps.running ?? [];
  const runningIds = new Set(running.map((a) => a.id));
  const recent = (apps.recent ?? []).filter((a) => !runningIds.has(a.id)).sort((x, y) => (y.lastSeen ?? 0) - (x.lastSeen ?? 0));
  const appRow = (a, subtitle) => row({ title: a.name, subtitle, value: statusOf(a), onClick: () => choose(a), chevron: true });
  const el = screen({ title: "Choose an App", back: { label: "Apps", href: appsHref(view) } },
    running.length > 0 && group({ header: "Open now" }, running.map((a) => appRow(a))),
    recent.length > 0 && group({ header: "Seen recently" }, recent.map((a) => appRow(a, a.lastSeen ? "Last open " + f.ago(Math.max(0, now - a.lastSeen)) : ""))),
    !running.length && !recent.length && empty("No apps seen yet", ""),
    h("p", { class: "page-footer", text: "Only apps the computer has seen show up here. If one is missing, ask for it to be opened once on the computer." }));
  return { el, live: true };
}
