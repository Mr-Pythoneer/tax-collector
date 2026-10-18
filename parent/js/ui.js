// Building blocks for the screens: grouped lists like iOS Settings, a navigation bar, switches,
// sheets. Every bit of text goes in as a text node (textContent), never as HTML, because
// much of it comes from the student's computer.

/**
 * h("div", { class: "x", onclick: fn, attrs: { "aria-label": "…" } }, "text", child, [more])
 * Strings become text nodes. null, undefined and false are skipped.
 */
export function h(tag, props = {}, ...children) {
  const el = tag === "svg" || props?.svg ? document.createElementNS("http://www.w3.org/2000/svg", tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(props ?? {})) {
    if (v === undefined || v === null || v === false || k === "svg") continue;
    if (k === "class") el.setAttribute("class", Array.isArray(v) ? v.filter(Boolean).join(" ") : v);
    else if (k === "text") el.textContent = String(v);
    else if (k === "attrs") for (const [a, av] of Object.entries(v)) av !== undefined && av !== null && av !== false && el.setAttribute(a, av === true ? "" : String(av));
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k === "value") el.value = String(v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k in el && typeof v !== "string") el[k] = v;
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(el, c);
    else el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

const svgNS = "http://www.w3.org/2000/svg";
function svgPath(d, cls) {
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", cls);
  const path = document.createElementNS(svgNS, "path");
  path.setAttribute("d", d);
  svg.append(path);
  return svg;
}
export const chevron = () => svgPath("M9 5l7 7-7 7", "chev");
const backChevron = () => svgPath("M15 4l-8 8 8 8", "back-chev");
export const checkmark = () => svgPath("M5 12.5l4.5 4.5L19 7", "check");

// ---------------------------------------------------------------- page frame

/**
 * A screen: navigation bar, optional large title, then content.
 * back: { label, href } · action: { label, onClick, disabled }
 */
export function screen({ title, large = false, back, action, className }, ...content) {
  // Like iOS: when the back label and the title won't both fit, the back label becomes "Back".
  const tight = back && back.label.length > 6 && (back.label.length > 14 || (!large && back.label.length + String(title).length + (action ? action.label.length : 0) > 24));
  if (tight) back = { ...back, label: "Back", fullLabel: back.label };
  const bar = h("header", { class: ["navbar", large && "navbar-large"] },
    h("div", { class: "navbar-side navbar-left" },
      back && h("a", { class: "nav-back", href: back.href, attrs: { "aria-label": "Back to " + (back.fullLabel ?? back.label) } }, backChevron(), h("span", { text: back.label }))),
    h("h1", { class: "navbar-title", text: title, attrs: { "aria-hidden": large ? "true" : null } }),
    h("div", { class: "navbar-side navbar-right" },
      action && h("button", { class: ["nav-action", action.bold && "bold"], type: "button", onclick: action.onClick, disabled: !!action.disabled, text: action.label })));
  return h("div", { class: ["screen", className] },
    bar,
    h("main", { class: "content" }, large && h("h1", { class: "large-title", text: title }), content));
}

/** A rounded group of rows with an optional header and footer. */
export function group({ header, footer, className, headerTone } = {}, ...rows) {
  const items = rows.flat().filter(Boolean);
  return h("section", { class: ["group", className] },
    header && h("h2", { class: ["group-header", headerTone && "tone-" + headerTone] }, header),
    items.length ? h("div", { class: "group-body" }, items) : null,
    footer && h("p", { class: "group-footer" }, footer));
}

/**
 * One row. title, subtitle, value (right side), dot (a color class), href or onClick,
 * chevron, tone ("tint" | "destructive"), accessory (a Node), lines (extra text lines).
 */
export function row({ title, subtitle, value, href, onClick, chevron: showChevron, tone, accessory, dot, lines, className, disabled, label, selected }) {
  const tag = href ? "a" : onClick ? "button" : "div";
  const props = { class: ["row", tone && "tone-" + tone, (href || onClick) && "tappable", className, disabled && "disabled", selected && "selected"] };
  if (href) props.href = href;
  if (onClick) {
    props.type = "button";
    props.onclick = onClick;
    props.disabled = !!disabled;
  }
  if (label) props.attrs = { "aria-label": label };
  if (selected !== undefined) props.attrs = { ...props.attrs, "aria-pressed": String(!!selected) };
  return h(tag, props,
    dot && h("span", { class: ["dot", dot], attrs: { "aria-hidden": "true" } }),
    h("span", { class: "row-main" },
      h("span", { class: "row-title" }, title),
      subtitle && h("span", { class: "row-subtitle" }, subtitle),
      (lines ?? []).filter(Boolean).map((l) => (l instanceof Node ? l : h("span", { class: "row-line" }, l)))),
    value !== undefined && value !== null && value !== "" && h("span", { class: "row-value" }, value),
    accessory,
    selected && checkmark(),
    (showChevron ?? !!href) && chevron());
}

/** A full-width button row: "Lock now", "Delete Task". */
export const buttonRow = ({ text, onClick, tone = "tint", disabled, bold }) =>
  h("button", { class: ["row", "button-row", "tappable", "tone-" + tone, bold && "bold", disabled && "disabled"], type: "button", onclick: onClick, disabled: !!disabled, text });

/** An iOS switch. */
export function toggle({ checked, onChange, label, disabled }) {
  const input = h("input", { type: "checkbox", class: "switch", checked: !!checked, disabled: !!disabled, attrs: { role: "switch", "aria-label": label } });
  input.addEventListener("change", () => onChange(input.checked, input));
  return input;
}

export const toggleRow = ({ title, subtitle, checked, onChange, disabled }) =>
  row({ title, subtitle, accessory: toggle({ checked, onChange, label: title, disabled }), className: "toggle-row" });

/** A segmented control. options: [{ value, label }]. */
export function segmented({ options, value, onChange, label }) {
  const wrap = h("div", { class: "segmented", attrs: { role: "radiogroup", "aria-label": label } });
  const buttons = options.map((o) => {
    const b = h("button", { type: "button", class: ["segment", o.value === value && "selected"], text: o.label, attrs: { role: "radio", "aria-checked": String(o.value === value) } });
    b.addEventListener("click", () => {
      for (const other of buttons) {
        other.classList.toggle("selected", other === b);
        other.setAttribute("aria-checked", String(other === b));
      }
      onChange(o.value);
    });
    return b;
  });
  wrap.append(...buttons);
  return wrap;
}

/** A row holding a labelled input. */
export function fieldRow({ label, input, hint }) {
  const id = "f" + Math.random().toString(36).slice(2, 9);
  input.id = id;
  return h("div", { class: "row field-row" },
    h("label", { class: "field-label", for: id, text: label }),
    input,
    hint && h("span", { class: "row-value", text: hint }));
}

export const spinner = (label = "Working") => h("span", { class: "spinner", attrs: { role: "progressbar", "aria-label": label } });

export const pill = (text, tone = "pending") => h("span", { class: ["pill", "pill-" + tone], text });

export const empty = (title, text) => h("div", { class: "empty" }, h("p", { class: "empty-title", text: title }), text && h("p", { class: "empty-text", text }));

export const note = (text, tone) => h("p", { class: ["note", tone && "tone-" + tone] }, text);

// ---------------------------------------------------------------- sheets

/**
 * An action sheet from the bottom, like iOS. Resolves to the chosen action's value, or null.
 * actions: [{ text, value, tone }]
 */
export function sheet({ title, message, actions, cancel = "Cancel" }) {
  return new Promise((resolve) => {
    const prev = document.activeElement;
    let done = false;
    const close = (value) => {
      if (done) return;
      done = true;
      overlay.classList.remove("open");
      setTimeout(() => overlay.remove(), 220);
      document.removeEventListener("keydown", onKey);
      prev?.focus?.();
      resolve(value);
    };
    const onKey = (e) => e.key === "Escape" && close(null);
    const panel = h("div", { class: "sheet", attrs: { role: "dialog", "aria-modal": "true", "aria-label": title ?? message ?? "Choose" } },
      h("div", { class: "sheet-group" },
        (title || message) && h("div", { class: "sheet-head" }, title && h("p", { class: "sheet-title", text: title }), message && h("p", { class: "sheet-message", text: message })),
        actions.map((a) => h("button", { type: "button", class: ["sheet-button", a.tone && "tone-" + a.tone], text: a.text, onclick: () => close(a.value ?? a.text) }))),
      h("div", { class: "sheet-group" }, h("button", { type: "button", class: "sheet-button bold", text: cancel, onclick: () => close(null) })));
    const overlay = h("div", { class: "sheet-overlay", onclick: (e) => e.target === overlay && close(null) }, panel);
    document.body.append(overlay);
    document.addEventListener("keydown", onKey);
    panel.tabIndex = -1;
    requestAnimationFrame(() => {
      overlay.classList.add("open");
      panel.focus({ preventScroll: true });
    });
  });
}

/** "Are you sure?" with one destructive (or plain) choice. Resolves true or false. */
export async function confirm({ title, message, ok, tone = "destructive" }) {
  return (await sheet({ title, message, actions: [{ text: ok, value: true, tone }] })) === true;
}
