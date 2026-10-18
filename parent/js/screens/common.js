// Pieces several computer screens share.
import { h, screen, group, row, buttonRow, spinner, note, confirm } from "../ui.js";
import * as f from "../format.js";

/** Now on the server's clock, as best this phone can tell: due times and locks are judged by it. */
export const nowOf = (view) => f.serverNow(view?.live, view?.liveAt);

/** The freshness line, honest about what this phone actually knows right now. */
export function freshnessOf(view) {
  const p = view.problem?.kind;
  const since = view.fetchedAt ? " since " + f.when(view.fetchedAt, Date.now(), undefined) : "";
  if (p === "unauthorized" || p === "gone") return { tone: "silent", text: "Not updating" + since };
  if (p === "reset" || p === "unknown") return { tone: "late", text: "Waiting for the computer to connect to the server again" };
  if (view.netError) return { tone: "late", text: "No connection to the server" + since };
  if (!view.answered) return { tone: "unknown", text: "Checking…" };
  return f.freshness(view.live, zone(view), nowOf(view));
}

export const zone = (view) => f.zoneOf(view?.state);

/** The parent app hides controls whose capability the computer doesn't list (§10). */
export const can = (view, capability) => (view?.state?.computer?.capabilities ?? []).includes(capability);

export const homeHref = (view) => "#/c/" + encodeURIComponent(view.rec.id);
export const backTo = (view) => ({ label: view.rec.computerName, href: homeHref(view) });

/** Problems and connection trouble, as a note at the top of a screen. */
export function problemNotes(view, app) {
  const out = [];
  if (view.netError) {
    out.push(note(view.fetchedAt ? `${view.netError} Showing what it knew ${f.ago(Date.now() - view.fetchedAt)}.` : view.netError, "warn"));
  }
  const p = view.problem;
  if (p) {
    out.push(note(p.text, ["unopenable", "unauthorized", "gone"].includes(p.kind) ? "bad" : "warn"));
    if ((p.kind === "unauthorized" || p.kind === "gone") && app) {
      out.push(group({}, buttonRow({
        text: "Forget This Computer on This Phone",
        tone: "destructive",
        onClick: async () => {
          if (await confirm({ title: `Forget ${view.rec.computerName}?`, message: "This phone stops showing it. To watch it again, pair with a new code.", ok: "Forget" })) {
            await app.forget(view.rec.id);
            app.replace("/");
          }
        },
      })));
    }
  }
  return out;
}

/** A screen to show while there's no state yet. */
export function waiting(view, title, app) {
  return screen({ title, back: backTo(view) },
    problemNotes(view, app),
    !view.problem && group({}, h("div", { class: "row progress-row" }, spinner(), h("span", { text: `Waiting for the first update from ${view.rec.computerName}…` }))));
}

/** Rows for commands this phone sent, newest first, with where each one is. */
export function commandRows(view, { types, limit = 5 } = {}) {
  return view.commands
    .filter((c) => !types || types.includes(c.type))
    .slice(0, limit)
    .map((c) => {
      const label = f.phaseLabel(c, view.live);
      return row({
        title: c.label,
        lines: [h("span", { class: ["row-line", "phase", "phase-" + label.tone] }, h("span", { class: "phase-text", text: label.text }), h("span", { text: " · " + f.when(c.sentAt, Date.now(), undefined) }))],
        className: "command-row",
      });
    });
}

/** Sends a command from a screen, then shows where it got to in the toast area. */
export async function act(app, view, type, args) {
  return app.send(view, type, args);
}

export { h };
