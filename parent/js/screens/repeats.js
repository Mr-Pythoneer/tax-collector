// Repeating tasks: every N days, or every N weeks on chosen days.
import { h, screen, group, row, buttonRow, segmented, fieldRow, empty, confirm } from "../ui.js";
import * as f from "../format.js";
import * as lc from "../linkcrypto.js";
import { nowOf, zone, can, backTo, problemNotes, waiting } from "./common.js";

const listHref = (view) => "#/c/" + encodeURIComponent(view.rec.id) + "/repeats";

export function renderList({ app, view }) {
  if (!view.state) return { el: waiting(view, "Repeating Tasks", app), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const repeats = view.state.repeats ?? [];
  const id = encodeURIComponent(view.rec.id);
  const el = screen({ title: "Repeating Tasks", back: backTo(view), action: can(view, "repeats") && { label: "Add", bold: true, onClick: () => app.go(`/c/${id}/repeats/new`) } },
    problemNotes(view, app),
    repeats.length
      ? group({ footer: "Each one adds its next task to the list by itself. Stopping one keeps the tasks it already added." },
        repeats.map((r) => row({ title: r.title, subtitle: r.schedule || f.scheduleText(r), lines: [r.currentDue && "Next due " + f.when(r.currentDue, now, tz)], href: `#/c/${id}/repeat/${encodeURIComponent(r.id)}` })))
      : empty("No repeating tasks", "Add one for things like music practice or weekly chores."));
  return { el, live: true };
}

export function renderRepeat({ app, view, params }) {
  if (!view.state) return { el: waiting(view, "Repeating Task", app), live: true };
  const r = (view.state.repeats ?? []).find((x) => x.id === params[1]);
  const back = { label: "Repeating", href: listHref(view) };
  if (!r) return { el: screen({ title: "Repeating Task", back }, empty("This repeat has stopped", "")), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const stop = async () => {
    if (await confirm({ title: `Stop repeating “${r.title}”?`, message: "Tasks it already added stay on the list.", ok: "Stop Repeating" })) {
      app.send(view, "stopRepeat", { id: r.id });
      app.back(listHref(view).slice(1));
    }
  };
  const [y, m, d] = (r.startDate ?? "").split("-").map(Number);
  const start = y ? f.longDate(Date.UTC(y, m - 1, d, 12), "UTC") : r.startDate;
  const el = screen({ title: "Repeating Task", back },
    problemNotes(view, app),
    h("div", { class: "detail-head" }, h("h2", { class: "detail-title", text: r.title }), h("p", { class: "detail-sub", text: r.schedule || f.scheduleText(r) })),
    group({},
      r.currentDue && row({ title: "Next due", value: f.when(r.currentDue, now, tz) }),
      row({ title: "Starting", value: start })),
    r.details && group({ header: "Details" }, h("div", { class: "row text-row", text: r.details })),
    can(view, "repeats") && group({}, buttonRow({ text: "Stop Repeating", tone: "destructive", onClick: stop })));
  return { el, live: true };
}

export function renderForm({ app, view }) {
  if (!view.state) return { el: waiting(view, "New Repeating Task", app), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const z = f.zoned(now, tz);
  const model = { unit: "weeks", interval: 1, weekdays: new Set([2, 3, 4, 5, 6]), minuteOfDay: 18 * 60 };

  const title = h("input", { type: "text", maxlength: 200, placeholder: "Title, like “Practice piano”", autocomplete: "off" });
  const details = h("textarea", { maxlength: 2000, rows: 3, placeholder: "Details (optional)" });
  const time = h("input", { type: "time", value: "18:00" });
  const startDate = h("input", { type: "date", value: `${z.y}-${String(z.m).padStart(2, "0")}-${String(z.d).padStart(2, "0")}` });
  const preview = h("p", { class: "group-footer preview" });
  const error = h("p", { class: "form-error", attrs: { role: "alert" } });

  const intervalValue = h("span", { class: "stepper-value" });
  const stepperRow = h("div", { class: "row stepper-row" },
    h("span", { class: "row-title stepper-label" }),
    h("div", { class: "stepper" },
      h("button", { type: "button", class: "stepper-button", text: "−", attrs: { "aria-label": "Fewer" }, onclick: () => step(-1) }),
      intervalValue,
      h("button", { type: "button", class: "stepper-button", text: "+", attrs: { "aria-label": "More" }, onclick: () => step(1) })));
  const max = () => (model.unit === "days" ? 365 : 52);
  const step = (d) => {
    model.interval = Math.min(max(), Math.max(1, model.interval + d));
    draw();
  };

  const dayButtons = [1, 2, 3, 4, 5, 6, 7].map((w) => {
    const b = h("button", { type: "button", class: "day-button", text: f.DAY_LETTERS[w], attrs: { "aria-label": ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][w] } });
    b.addEventListener("click", () => {
      if (model.weekdays.has(w)) model.weekdays.delete(w);
      else model.weekdays.add(w);
      draw();
    });
    return { b, w };
  });
  const daysRow = h("div", { class: "row days-row", attrs: { role: "group", "aria-label": "Days of the week" } }, dayButtons.map((d) => d.b));

  function draw() {
    model.interval = Math.min(max(), model.interval);
    const unitWord = model.unit === "days" ? (model.interval === 1 ? "day" : "days") : model.interval === 1 ? "week" : "weeks";
    stepperRow.querySelector(".stepper-label").textContent = "Every";
    intervalValue.textContent = `${model.interval} ${unitWord}`;
    daysRow.classList.toggle("hidden", model.unit !== "weeks");
    for (const { b, w } of dayButtons) {
      b.classList.toggle("selected", model.weekdays.has(w));
      b.setAttribute("aria-pressed", String(model.weekdays.has(w)));
    }
    const [hh, mm] = time.value.split(":").map(Number);
    model.minuteOfDay = Number.isInteger(hh) && Number.isInteger(mm) ? hh * 60 + mm : model.minuteOfDay;
    preview.textContent = model.unit === "weeks" && model.weekdays.size === 0 ? "Choose at least one day." : f.scheduleText({ ...model, weekdays: [...model.weekdays] }) + ".";
  }
  time.addEventListener("input", draw);

  const save = () => {
    const name = title.value.trim();
    if (!name) return void (error.textContent = "Give it a title.");
    if (model.unit === "weeks" && model.weekdays.size === 0) return void (error.textContent = "Choose at least one day of the week.");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(startDate.value)) return void (error.textContent = "Choose a start date.");
    app.send(view, "addRepeat", {
      repeat: {
        id: lc.uuid(), title: name, details: details.value.trim(), unit: model.unit, interval: model.interval,
        weekdays: model.unit === "weeks" ? [...model.weekdays].sort((a, b) => a - b) : [],
        minuteOfDay: model.minuteOfDay, startDate: startDate.value,
      },
    });
    app.back(listHref(view).slice(1));
  };

  draw();
  const el = screen({ title: "New Repeating Task", back: { label: "Cancel", href: listHref(view) }, action: { label: "Add", bold: true, onClick: save } },
    group({}, h("div", { class: "row input-row" }, title), h("div", { class: "row input-row" }, details)),
    h("section", { class: "group" },
      h("h2", { class: "group-header", text: "Repeats" }),
      h("div", { class: "group-body" },
        h("div", { class: "row segmented-row" }, segmented({ label: "How it repeats", options: [{ value: "weeks", label: "On chosen days" }, { value: "days", label: "Every few days" }], value: model.unit, onChange: (v) => ((model.unit = v), draw()) })),
        stepperRow,
        daysRow,
        fieldRow({ label: "At", input: time }),
        fieldRow({ label: "Starting", input: startDate })),
      preview),
    error);
  return { el, live: false, focus: () => title.focus({ preventScroll: true }) };
}
