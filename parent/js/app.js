// The parent app's shell: what's paired, fetching each computer's state, sending commands and
// following them, and showing the right screen for the address.
import * as db from "./db.js";
import * as phone from "./phone.js";
import * as lc from "./linkcrypto.js";
import * as f from "./format.js";
import { h } from "./ui.js";
import * as computersScreen from "./screens/computers.js";
import * as pairScreen from "./screens/pair.js";
import * as statusScreen from "./screens/status.js";
import * as lockScreen from "./screens/lock.js";
import * as tasksScreen from "./screens/tasks.js";
import * as repeatsScreen from "./screens/repeats.js";
import * as appsScreen from "./screens/apps.js";
import * as settingsScreen from "./screens/settings.js";
import * as moreScreens from "./screens/more.js";

const POLL_ACTIVE = 4_000;
const POLL_FAST = 1_000;
const POLL_LIST = 20_000;
const FAST_FOR = 30_000;

const ROUTES = [
  [/^\/$/, computersScreen.render, "computers"],
  [/^\/pair$/, pairScreen.render, "pair"],
  [/^\/c\/([^/]+)$/, statusScreen.render],
  [/^\/c\/([^/]+)\/lock$/, lockScreen.render],
  [/^\/c\/([^/]+)\/tasks$/, tasksScreen.renderList],
  [/^\/c\/([^/]+)\/tasks\/new$/, tasksScreen.renderForm],
  [/^\/c\/([^/]+)\/task\/([^/]+)$/, tasksScreen.renderTask],
  [/^\/c\/([^/]+)\/task\/([^/]+)\/edit$/, tasksScreen.renderForm],
  [/^\/c\/([^/]+)\/repeats$/, repeatsScreen.renderList],
  [/^\/c\/([^/]+)\/repeats\/new$/, repeatsScreen.renderForm],
  [/^\/c\/([^/]+)\/repeat\/([^/]+)$/, repeatsScreen.renderRepeat],
  [/^\/c\/([^/]+)\/apps$/, appsScreen.renderList],
  [/^\/c\/([^/]+)\/apps\/add$/, appsScreen.renderPicker],
  [/^\/c\/([^/]+)\/settings$/, settingsScreen.render],
  [/^\/c\/([^/]+)\/message$/, moreScreens.renderMessage],
  [/^\/c\/([^/]+)\/activity$/, moreScreens.renderActivity],
  [/^\/c\/([^/]+)\/devices$/, moreScreens.renderDevices],
];

const app = {
  views: new Map(),
  route: null,
  screen: null,
  history: [],
  pendingCode: null,
  persisted: null,
  booted: false,
};

// iPadOS Safari says "Macintosh"; touch points tell it apart from a Mac.
export const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
export const isStandalone = () => navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;

// ---------------------------------------------------------------- computers and their state

function newView(rec, cached) {
  return {
    rec,
    state: cached?.state ?? null,
    meta: cached?.meta ?? null,
    live: cached?.live ?? null,
    etag: null, // fetch the full copy once per launch
    lastSeq: cached?.lastSeq ?? -1,
    fetchedAt: cached?.fetchedAt ?? 0,
    liveAt: cached?.liveAt ?? cached?.fetchedAt ?? 0, // when (phone time) live.serverTime arrived
    answered: false, // has the server answered since the app opened?
    instance: cached?.instance ?? rec.instance ?? null,
    problem: null,
    unauthorizedSince: 0,
    netError: null,
    commands: [],
    lastPoll: 0,
    fastUntil: 0,
    inflight: false,
    signature: "",
  };
}

async function loadComputers() {
  const recs = await db.computers.all();
  for (const rec of recs.sort((a, b) => a.pairedAt - b.pairedAt)) {
    const view = newView(rec, await db.cache.get(rec.id));
    view.commands = (await db.commands.forComputer(rec.id)).sort((a, b) => b.sentAt - a.sentAt);
    app.views.set(rec.id, view);
  }
}

async function saveCache(view) {
  const { state, meta, live, lastSeq, fetchedAt, liveAt, instance } = view;
  await db.cache.put({ id: view.rec.id, state, meta, live, lastSeq, fetchedAt, liveAt, instance }).catch(() => {});
}

/** The server's clock now, as best this phone can tell. */
export const serverNowOf = (view) => f.serverNow(view?.live, view?.liveAt);

const FORGET_AFTER = 2 * 60_000;

function problemFor(view, r) {
  const name = view.rec.computerName;
  switch (r.kind) {
    case "unauthorized": {
      if (r.instance && view.instance && r.instance !== view.instance) {
        return { kind: "reset", short: "The server was reset: waiting for the computer", text: `The server was reset. Waiting for ${name} to connect to it again.` };
      }
      // A server that lost a computer's files (but kept its own) answers 401 until the computer
      // registers its phones again, so give that a couple of minutes before suggesting Forget.
      view.unauthorizedSince ||= Date.now();
      if (Date.now() - view.unauthorizedSince < FORGET_AFTER) {
        return { kind: "unknown", short: "The server doesn't know this phone right now", text: `The server doesn't know this phone right now. If the server lost its data, ${name} sets this phone up again when it next connects.` };
      }
      return { kind: "unauthorized", short: "This phone isn't connected any more", text: `This phone isn't connected to ${name} any more. It may have been removed on the computer or from another phone.` };
    }
    case "forbidden":
      return { kind: "unauthorized", short: "This phone isn't connected any more", text: "The server says this phone belongs to another computer." };
    case "gone":
      return { kind: "gone", short: "Unlinked from the server", text: `${name} was unlinked from the server${r.unlinkedAt ? " " + f.ago(Date.now() - r.unlinkedAt) : ""}. Pair again if you still want to watch it.` };
    case "unopenable":
      return { kind: "unopenable", short: "The last update wouldn't open", text: "The server sent an update this phone couldn't open. Someone may have changed the server." };
    case "old":
      return { kind: "old", short: "The server sent old news", text: "The server sent older news than this phone has already shown, so the phone ignored it." };
    case "empty":
      return view.state
        ? { kind: "nocopy", short: "No updates for this phone", text: `${name} isn't sending this phone updates right now. What's shown is from before.` }
        : { kind: "empty", short: "Waiting for the first update", text: `Waiting for the first update from ${name}.` };
    default:
      return null;
  }
}

async function poll(view) {
  if (view.inflight) return;
  view.inflight = true;
  view.lastPoll = Date.now();
  try {
    const r = await phone.fetchState({ computer: view.rec, etag: view.etag, lastSeq: view.lastSeq });
    view.netError = null;
    view.answered = true;
    if (r.live) {
      view.live = { ...view.live, ...r.live };
      if (r.live.serverTime != null) view.liveAt = Date.now();
    }
    if (r.kind !== "unauthorized") view.unauthorizedSince = 0;
    if (r.kind === "state") {
      Object.assign(view, { state: r.state, etag: r.etag, meta: r.meta, lastSeq: r.state.seq, fetchedAt: Date.now() });
      await phone.catchUpCounter(r.state, view.rec, db.counters).catch(() => {});
      if (r.live?.instance) view.instance = r.live.instance;
      view.problem = null;
      await saveCache(view);
    } else if (r.kind === "same" || r.kind === "empty") {
      view.fetchedAt = Date.now();
      if (r.live?.instance) view.instance = r.live.instance;
      view.problem = problemFor(view, r);
    } else {
      view.problem = problemFor(view, r);
    }
  } catch (e) {
    view.netError = e.code === "network" ? "This phone can't reach the server right now." : e.message;
  } finally {
    view.inflight = false;
  }
  await updatePhases(view);
  if (!view.netError) await resendUnconfirmed(view);
  changed(view);
}

/**
 * Sends again the commands whose answer was lost: the same sealed box, so if the first one did
 * arrive the computer just refuses the copy as replayed. Only within the computer's 10-minute
 * freshness window; after that the box would be refused as stale anyway.
 */
async function resendUnconfirmed(view) {
  for (const cmd of view.commands) {
    if (cmd.final || cmd.seq || !cmd.box || cmd.resending) continue;
    if (Date.now() - (cmd.at ?? cmd.sentAt) > 9 * 60_000) {
      Object.assign(cmd, { phase: "failed", reason: "no connection for too long", final: { outcome: "failed", reason: "no connection for too long" }, finalAt: Date.now() });
      await db.commands.put(cmd).catch(() => {});
      continue;
    }
    cmd.resending = true;
    try {
      const res = await phone.postCommand(view.rec, cmd.box);
      Object.assign(cmd, { seq: res.json.seq, receivedAt: res.json.receivedAt, instance: res.instance, error: null, box: null });
    } catch (e) {
      if (!phone.maybeSent(e)) Object.assign(cmd, { phase: "failed", reason: e.message, error: e.message, box: null, final: { outcome: "failed", reason: e.message }, finalAt: Date.now() });
    } finally {
      cmd.resending = false;
    }
    await db.commands.put(cmd).catch(() => {});
  }
}

/** Works out where each sent command is, and keeps the final answer once it's seen. */
async function updatePhases(view) {
  const ctx = { state: view.state, meta: view.meta, live: view.live, deviceId: view.rec.deviceId };
  for (const cmd of view.commands) {
    // A send that failed may still have reached the computer: its result wins if it shows up.
    if (cmd.final?.outcome === "failed" && phone.resultFor(view.state, view.rec.deviceId, cmd.id)) cmd.final = null;
    if (cmd.final) continue;
    const { phase, reason } = phone.commandPhase(cmd, ctx);
    if (phase === cmd.phase && reason === cmd.reason) continue;
    cmd.phase = phase;
    cmd.reason = reason;
    if (f.isFinal(phase)) {
      cmd.final = { outcome: phase, reason };
      cmd.finalAt = Date.now();
    }
    await db.commands.put(cmd).catch(() => {});
  }
}

function signature(view) {
  const fr = f.freshness(view.live, f.zoneOf(view.state), serverNowOf(view)).text;
  return [view.lastSeq, view.meta?.ackedUpTo, view.meta?.lastCmdSeq, view.live?.computerAwake, fr, view.problem?.kind, view.netError,
    view.commands.slice(0, 8).map((c) => c.phase).join()].join("|");
}

function changed(view) {
  const sig = signature(view);
  renderToasts();
  if (sig === view.signature) return;
  view.signature = sig;
  const id = app.route?.params?.[0];
  if (app.route?.name === "computers" || id === view.rec.id) refreshScreen();
}

function tick() {
  if (document.visibilityState !== "visible") return;
  const now = Date.now();
  const currentId = app.route?.params?.[0];
  for (const view of app.views.values()) {
    if (view.problem?.kind === "gone") continue;
    const interval = view.fastUntil > now ? POLL_FAST : view.rec.id === currentId ? POLL_ACTIVE : app.route?.name === "computers" ? POLL_LIST : null;
    if (interval !== null && now - view.lastPoll >= interval) poll(view);
  }
  renderToasts();
}

// ---------------------------------------------------------------- commands

/** Sends one command and follows it. Returns the tracked command. */
async function send(view, type, args) {
  const cmd = { id: lc.uuid(), computer: view.rec.id, type, args, label: f.commandLabel(type, args, view.state), sentAt: Date.now(), seq: null, phase: "sending", reason: "" };
  view.commands.unshift(cmd);
  renderToasts();
  await db.commands.put(cmd).catch(() => {});
  try {
    const sent = await phone.sendCommand({ computer: view.rec, store: db.counters, type, args, id: cmd.id });
    Object.assign(cmd, { seq: sent.seq, n: sent.n, at: sent.at, receivedAt: sent.receivedAt, instance: sent.instance });
  } catch (e) {
    cmd.error = e.message;
    if (phone.maybeSent(e) && e.box) {
      // Kept, and sent again when the server answers: see resendUnconfirmed.
      Object.assign(cmd, { phase: "unconfirmed", reason: e.message, box: e.box, n: e.n, at: e.at });
    } else {
      Object.assign(cmd, { phase: "failed", reason: e.message, final: { outcome: "failed", reason: e.message }, finalAt: Date.now() });
    }
    if (e.code === "unauthorized" || e.code === "gone") view.problem = problemFor(view, { kind: e.code, unlinkedAt: e.unlinkedAt });
  }
  await db.commands.put(cmd).catch(() => {});
  db.commands.prune(view.rec.id).catch(() => {});
  view.fastUntil = Date.now() + FAST_FOR;
  view.lastPoll = 0;
  await updatePhases(view);
  changed(view);
  return cmd;
}

// ---------------------------------------------------------------- toasts

const toastBox = h("div", { class: "toasts", attrs: { "aria-live": "polite" } });

function renderToasts() {
  const now = Date.now();
  const shown = [];
  for (const view of app.views.values()) {
    for (const cmd of view.commands) {
      if (now - cmd.sentAt > 10 * 60_000) continue;
      if (cmd.finalAt && now - cmd.finalAt > 5_000) continue;
      if (cmd.dismissed) continue;
      shown.push({ cmd, view });
    }
  }
  shown.sort((a, b) => b.cmd.sentAt - a.cmd.sentAt);
  const items = shown.slice(0, 3).map(({ cmd, view }) => {
    const label = f.phaseLabel(cmd, view.live);
    return h("div", { class: ["toast", "toast-" + label.tone] },
      h("span", { class: "toast-label", text: cmd.label }),
      h("span", { class: "toast-phase", text: label.text }),
      h("button", { type: "button", class: "toast-close", attrs: { "aria-label": "Hide" }, text: "×", onclick: () => ((cmd.dismissed = true), renderToasts()) }));
  });
  const key = items.map((i) => i.textContent).join("|");
  if (toastBox.dataset.key === key) return;
  toastBox.dataset.key = key;
  toastBox.replaceChildren(...items);
}

// ---------------------------------------------------------------- pairing and forgetting

async function addComputer(rec) {
  await db.computers.put(rec);
  const view = newView(rec, null);
  view.fastUntil = Date.now() + FAST_FOR; // the computer uploads its first state right after pairing
  app.views.set(rec.id, view);
  try {
    app.persisted = (await navigator.storage?.persist?.()) ?? app.persisted;
  } catch {
    // not available: the screens say so
  }
  poll(view);
  return view;
}

async function forget(id) {
  app.views.delete(id);
  await db.computers.delete(id);
}

// ---------------------------------------------------------------- screens

function parseRoute() {
  const path = location.hash.replace(/^#/, "") || "/";
  for (const [re, render, name] of ROUTES) {
    const m = path.match(re);
    if (m) return { path, render, name: name ?? "computer", params: m.slice(1).map(decodeURIComponent) };
  }
  return { path: "/", render: computersScreen.render, name: "computers", params: [] };
}

const api = {
  views: () => [...app.views.values()],
  view: (id) => app.views.get(id),
  send,
  poll,
  addComputer,
  forget,
  go: (path) => {
    location.hash = "#" + path;
  },
  replace: (path) => location.replace("#" + path),
  back: (fallback) => {
    if (app.history.at(-2) === fallback) history.back();
    else location.replace("#" + fallback);
  },
  refresh: () => refreshScreen(true),
  takePendingCode: () => {
    const c = app.pendingCode;
    app.pendingCode = null;
    return c;
  },
  persisted: () => app.persisted,
  prefs: db.prefs,
  isIOS,
  isStandalone,
};

/** A QR code from the computer opens …/#code=ABCDEFGHJK: keep the code, and clean the address. */
function takeCodeFromAddress() {
  const m = location.hash.match(/^#code=([A-Za-z0-9-]{10,13})$/);
  if (!m) return false;
  app.pendingCode = lc.normaliseCode(m[1]);
  history.replaceState(null, "", location.pathname + "#/pair");
  return true;
}

function render() {
  takeCodeFromAddress();
  const route = parseRoute();
  const sameScreen = app.route && app.route.path === route.path;
  app.route = route;
  if (!sameScreen) {
    if (app.history.at(-2) === route.path) app.history.pop();
    else if (app.history.at(-1) !== route.path) app.history.push(route.path);
    if (app.history.length > 50) app.history.shift();
  }
  const id = route.params[0];
  if (route.name === "computer" && !app.views.has(id)) {
    location.replace("#/");
    return;
  }
  app.screen?.cleanup?.();
  const result = route.render({ app: api, params: route.params, view: id ? app.views.get(id) : null });
  app.screen = result;
  root.replaceChildren(result.el);
  window.scrollTo(0, 0);
  syncNavbar();
  result.focus?.();
  const view = id && app.views.get(id);
  if (view && Date.now() - view.lastPoll > 1500) poll(view);
}

/** Redraws a screen that shows live data, keeping the scroll position. Forms aren't redrawn. */
function refreshScreen(force = false) {
  if (!app.screen) return;
  if (!app.screen.live && !force) return void app.screen.update?.();
  if (document.activeElement && root.contains(document.activeElement) && /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) return;
  if (document.querySelector(".sheet-overlay")) return;
  const y = window.scrollY;
  const route = app.route;
  const id = route.params[0];
  if (route.name === "computer" && !app.views.has(id)) {
    location.replace("#/");
    return;
  }
  app.screen?.cleanup?.();
  const result = route.render({ app: api, params: route.params, view: id ? app.views.get(id) : null });
  app.screen = result;
  root.replaceChildren(result.el);
  window.scrollTo(0, y);
  syncNavbar();
}

/** A large title moves into the bar once it scrolls away, as on iOS. */
function syncNavbar() {
  document.querySelector(".navbar-large")?.classList.toggle("scrolled", window.scrollY > 44);
}

// ---------------------------------------------------------------- start

const root = h("div", { id: "root" });

async function boot() {
  document.body.append(root, toastBox);
  takeCodeFromAddress();
  try {
    await loadComputers();
  } catch (e) {
    root.replaceChildren(h("div", { class: "fatal" }, h("p", { text: "This browser won't let the app keep its data." }), h("p", { text: String(e.message ?? e) })));
    return;
  }
  try {
    app.persisted = (await navigator.storage?.persisted?.()) ?? null;
    if (app.views.size && !app.persisted) app.persisted = (await navigator.storage?.persist?.()) ?? app.persisted;
  } catch {
    app.persisted = null;
  }
  if ((location.hash === "" || location.hash === "#/" || location.hash === "#") && app.views.size === 1) {
    history.replaceState(null, "", location.pathname + "#/c/" + encodeURIComponent([...app.views.keys()][0]));
  }
  window.addEventListener("hashchange", render);
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && tick());
  window.addEventListener("online", () => app.views.forEach((v) => (v.lastPoll = 0)));
  window.addEventListener("scroll", syncNavbar, { passive: true });
  document.addEventListener("click", (e) => {
    const back = e.target.closest?.(".nav-back");
    if (!back) return;
    const target = back.getAttribute("href").replace(/^#/, "");
    if (app.history.at(-2) === target) {
      e.preventDefault();
      history.back();
    }
  });
  render();
  setInterval(tick, 500);
  app.booted = true;
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {});
}

boot();
