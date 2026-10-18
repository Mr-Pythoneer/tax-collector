// Tasks: grouped by day like the Mac's main window; one task with its proofs; add and edit.
import { h, screen, group, row, buttonRow, fieldRow, empty, note, confirm } from "../ui.js";
import * as f from "../format.js";
import * as lc from "../linkcrypto.js";
import { nowOf, zone, can, backTo, problemNotes, waiting } from "./common.js";

const DOTS = ["blue", "green", "orange", "teal", "pink", "brown", "mint", "yellow"];
const dotFor = (t) => (t.course ? "dot-course-" + DOTS[f.courseSlot(t.course, DOTS.length)] : "dot-none");
const tasksHref = (view) => "#/c/" + encodeURIComponent(view.rec.id) + "/tasks";
const taskHref = (view, t) => "#/c/" + encodeURIComponent(view.rec.id) + "/task/" + encodeURIComponent(t.id);

function badge(t) {
  const last = t.proofs?.at(-1);
  if (t.status !== "pending") return null;
  if (t.checking) return "Claude is checking a proof";
  if (last?.verdict === "rejected") return "Proof not accepted";
  if (last?.verdict === "error") return "Claude couldn't check the proof";
  return null;
}

export function renderList({ app, view }) {
  if (!view.state) return { el: waiting(view, "Tasks", app), live: true };
  const now = nowOf(view);
  const tz = zone(view);
  const sections = f.taskSections(view.state.tasks ?? [], now, tz);
  const taskRow = (t, kind) => {
    const time = kind === "day" ? f.time(t.due, tz) : kind === "done" ? f.taskStatus(t, now, tz) : kind === "penalty" ? "Locked until " + f.when(t.penaltyEndsAt, now, tz) : "Due " + f.when(t.due, now, tz);
    const sub = [t.course, time, t.source === "repeat" && "Repeats"].filter(Boolean).join(" · ");
    const b = badge(t);
    return row({ title: t.title, subtitle: sub, lines: [b && h("span", { class: ["row-line", "badge", t.checking ? "badge-wait" : "badge-bad"], text: b })], dot: dotFor(t), href: taskHref(view, t), className: kind === "done" ? "done-row" : "" });
  };
  const groups = sections.map((s) => group({
    header: s.subtitle ? [h("span", { text: s.title }), " ", h("span", { class: "header-sub", text: s.subtitle })] : s.title,
    headerTone: s.kind === "overdue" || s.kind === "penalty" ? "bad" : null,
    className: ["day-group", s.kind === "done" && "done-group"].filter(Boolean).join(" "),
  }, s.tasks.map((t) => taskRow(t, s.kind))));
  const el = screen({ title: "Tasks", back: backTo(view), action: can(view, "tasks") && { label: "Add", bold: true, onClick: () => app.go("/c/" + encodeURIComponent(view.rec.id) + "/tasks/new") } },
    problemNotes(view, app),
    groups.length ? groups : empty("Nothing to do", "Tasks you add here show up on the computer within seconds."));
  return { el, live: true };
}

export function renderTask({ app, view, params }) {
  if (!view.state) return { el: waiting(view, "Task", app), live: true };
  const t = (view.state.tasks ?? []).find((x) => x.id === params[1]);
  const back = { label: "Tasks", href: tasksHref(view) };
  if (!t) {
    return { el: screen({ title: "Task", back }, problemNotes(view, app), empty("This task is gone", "It was deleted, or finished more than two weeks ago.")), live: true };
  }
  const now = nowOf(view);
  const tz = zone(view);
  const pending = t.status === "pending";
  const editable = can(view, "tasks");
  const source = t.source === "blackbaud" ? "School calendar" : t.source === "repeat" ? "Repeating task" : "Added by hand";

  const proofRows = [...(t.proofs ?? [])].reverse().map((p) => {
    const onTime = p.at <= t.due;
    const verdict = f.proofVerdict(p);
    const canApprove = pending && can(view, "approveProof") && p.verdict !== "guardianApproved";
    const approve = async () => {
      const ok = await confirm({
        title: "Approve this proof?",
        message: `Sent ${f.when(p.at, now, tz)}. ${onTime ? "That was before the deadline, so the task counts as done on time." : "That was after the deadline, so it counts as late and the late penalty applies."}`,
        ok: "Approve",
        tone: "tint",
      });
      if (ok) app.send(view, "approveProof", { taskId: t.id, proofId: p.id });
    };
    return h("div", { class: "row proof-row" },
      h("div", { class: "row-main" },
        h("span", { class: "row-title", text: `Sent ${f.when(p.at, now, tz)}${p.files ? ` · ${p.files} file${p.files === 1 ? "" : "s"}` : " · written"}${onTime ? "" : " · late"}` }),
        p.note && h("span", { class: "row-line quote" }, h("span", { class: "quote-who", text: "Student's note: " }), p.note),
        p.verdict === "guardianApproved"
          ? h("span", { class: "row-line verdict verdict-guardianApproved" }, h("span", { class: "quote-who", text: f.approvalNote(p.reason) }))
          : h("span", { class: ["row-line", "verdict", "verdict-" + (p.verdict ?? "waiting")] },
            h("span", { class: "quote-who", text: verdict + (p.reason ? ": " : "") }), p.reason ?? ""),
        canApprove && h("button", { type: "button", class: "inline-button", text: "Approve This Proof", onclick: approve })));
  });

  const extRows = (t.extensions ?? []).slice().reverse().map((e) => row({
    title: `Asked for ${e.hoursAsked} more hour${e.hoursAsked === 1 ? "" : "s"}, ${f.when(e.at, now, tz)}`,
    lines: [e.decision === "granted" ? `Claude gave ${e.hoursGranted} hour${e.hoursGranted === 1 ? "" : "s"}` : e.decision === "denied" ? "Claude said no" : e.decision === "error" ? "Claude couldn't decide" : "Waiting for Claude", e.reason && "Reason: " + e.reason, e.answer && "Claude: " + e.answer],
  }));

  const excuse = async () => {
    if (await confirm({ title: `Excuse “${t.title}”?`, message: "It won't lock the computer or count as missed.", ok: "Excuse", tone: "tint" })) {
      app.send(view, "excuseTask", { id: t.id });
    }
  };
  const remove = async () => {
    if (await confirm({ title: `Delete “${t.title}”?`, message: "It disappears from the computer too.", ok: "Delete Task" })) {
      app.send(view, "deleteTask", { id: t.id });
      app.back(tasksHref(view).slice(1));
    }
  };

  const el = screen({ title: "Task", back, action: editable && pending && { label: "Edit", onClick: () => app.go(taskHref(view, t).slice(1) + "/edit") } },
    problemNotes(view, app),
    h("div", { class: "detail-head" },
      h("h2", { class: "detail-title", text: t.title }),
      t.course && h("p", { class: "detail-sub" }, h("span", { class: ["dot", dotFor(t)], attrs: { "aria-hidden": "true" } }), t.course)),
    group({},
      row({ title: "Due", value: f.when(t.due, now, tz) }),
      row({ title: "Status", value: f.taskStatus(t, now, tz) }),
      t.penaltyEndsAt && row({ title: "Late penalty", value: (t.penaltyEndsAt > now ? "until " : "ended ") + f.when(t.penaltyEndsAt, now, tz) }),
      row({ title: "From", value: source }),
      t.created && row({ title: "Added", value: f.when(t.created, now, tz) })),
    t.details && group({ header: "Details" }, h("div", { class: "row text-row", text: t.details })),
    group({ header: proofRows.length ? "Proofs" : "Proof", footer: pending && proofRows.length ? "Approving a proof settles the task, whatever Claude said. Its send time decides on time or late." : "" },
      proofRows.length ? proofRows : row({ title: "No proof sent yet", className: "muted-row" })),
    extRows.length > 0 && group({ header: "Asked for more time" }, extRows),
    editable && pending && group({}, buttonRow({ text: "Excuse This Task", onClick: excuse })),
    editable && group({}, buttonRow({ text: "Delete Task", tone: "destructive", onClick: remove })));
  return { el, live: true };
}

/** Add a task, or edit one: only the fields that changed are sent. */
export function renderForm({ app, view, params }) {
  if (!view.state) return { el: waiting(view, "Task", app), live: true };
  const editing = params[1] ? (view.state.tasks ?? []).find((x) => x.id === params[1]) : null;
  const now = nowOf(view);
  const tz = zone(view);
  const due = editing?.due ?? defaultDue(now, tz);
  const z = f.zoned(due, tz);
  const title = h("input", { type: "text", maxlength: 200, value: editing?.title ?? "", placeholder: "Title", autocomplete: "off" });
  const details = h("textarea", { maxlength: 2000, rows: 4, placeholder: "Details (optional)", value: editing?.details ?? "" });
  const date = h("input", { type: "date", value: `${z.y}-${String(z.m).padStart(2, "0")}-${String(z.d).padStart(2, "0")}` });
  const time = h("input", { type: "time", value: `${String(Math.floor(z.minute / 60)).padStart(2, "0")}:${String(z.minute % 60).padStart(2, "0")}` });
  const error = h("p", { class: "form-error", attrs: { role: "alert" } });
  const back = editing ? taskHref(view, editing).slice(1) : tasksHref(view).slice(1);
  // The fields show minutes; a due date from the school calendar may have seconds (11:59:59 PM).
  // So an unchanged date and time mean "leave the deadline alone", not "set it to this minute".
  const shownDate = date.value;
  const shownTime = time.value;

  const save = () => {
    const name = title.value.trim();
    const [y, m, d] = date.value.split("-").map(Number);
    const [hh, mm] = time.value.split(":").map(Number);
    if (!name) return void (error.textContent = "Give the task a title.");
    if (![y, m, d, hh, mm].every(Number.isInteger)) return void (error.textContent = "Choose a date and time.");
    const dueMs = f.wallTime(y, m, d, hh * 60 + mm, tz);
    if (!editing) {
      app.send(view, "addTask", { task: { id: lc.uuid(), title: name, details: details.value.trim(), due: dueMs } });
      app.back(back);
      return;
    }
    const args = { id: editing.id };
    if (name !== editing.title) args.title = name;
    if (details.value.trim() !== (editing.details ?? "").trim()) args.details = details.value.trim();
    if ((date.value !== shownDate || time.value !== shownTime) && dueMs !== editing.due) args.due = dueMs;
    if (Object.keys(args).length > 1) app.send(view, "editTask", args);
    app.back(back);
  };

  const zoneNote = tz && tz !== Intl.DateTimeFormat().resolvedOptions().timeZone ? `Times are the computer's (${tz.replace(/_/g, " ")}).` : "";
  const el = screen({ title: editing ? "Edit Task" : "New Task", back: { label: "Cancel", href: "#" + back }, action: { label: editing ? "Save" : "Add", bold: true, onClick: save } },
    editing && editing.status !== "pending" && note("This task is already settled; changes still go to the computer.", "warn"),
    group({}, h("div", { class: "row input-row" }, title), h("div", { class: "row input-row" }, details)),
    editing && (editing.details ?? "").length >= 500 && note("Only the first 500 characters of the details came to this phone. Changing them replaces the whole text."),
    group({ header: "Due", footer: [editing ? "You can move a deadline any time, even within its last 24 hours." : "", zoneNote].filter(Boolean).join(" ") },
      fieldRow({ label: "Date", input: date }),
      fieldRow({ label: "Time", input: time })),
    error);
  return { el, live: false, focus: () => !editing && title.focus({ preventScroll: true }) };
}

/** Tonight at 9 PM, or tomorrow at 8 AM if it's late already. */
function defaultDue(now, tz) {
  const z = f.zoned(now, tz);
  if (z.minute < 20 * 60) return f.wallTime(z.y, z.m, z.d, 21 * 60, tz);
  const t = new Date(Date.UTC(z.y, z.m - 1, z.d + 1));
  return f.wallTime(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate(), 8 * 60, tz);
}
