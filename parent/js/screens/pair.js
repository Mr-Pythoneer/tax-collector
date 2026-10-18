// Pair: type the code the computer shows, then compare the 6-digit number on both screens.
import { h, screen, group, row, buttonRow, fieldRow, spinner, note } from "../ui.js";
import * as phone from "../phone.js";
import * as lc from "../linkcrypto.js";

export function render({ app }) {
  const pending = app.takePendingCode();
  // From a QR code on an iPhone, Safari opened this, not the Home Screen app: say what to do.
  if (pending && app.isIOS() && !app.isStandalone()) return { el: openFromHomeScreen(pending), live: false };

  let controller = null;
  const body = h("div", { class: "pair-body" });
  const codeInput = h("input", {
    class: "code-input", type: "text", inputmode: "text", autocomplete: "one-time-code", autocapitalize: "characters",
    spellcheck: false, maxlength: 13, placeholder: "ABCDE-FGHJK", value: pending ? lc.formatPairingCode(pending) : "",
  });
  const nameInput = h("input", { type: "text", autocomplete: "off", maxlength: phone.DEVICE_NAME_MAX, placeholder: "Mom's iPhone", enterkeyhint: "go" });
  app.prefs.get("deviceName").then((n) => n && !nameInput.value && (nameInput.value = n)).catch(() => {});
  const error = h("p", { class: "form-error", attrs: { role: "alert" } });

  codeInput.addEventListener("input", () => {
    const clean = lc.normaliseCode(codeInput.value).slice(0, 10);
    const shown = lc.formatPairingCode(clean);
    if (codeInput.value !== shown) codeInput.value = shown;
    error.textContent = "";
  });

  const start = async () => {
    const code = lc.normaliseCode(codeInput.value);
    const name = phone.cleanDeviceName(nameInput.value);
    if (code.length !== 10) return void (error.textContent = "The code has 10 letters and numbers, like ABCDE-FGHJK.");
    if (!name) return void (error.textContent = "Give this phone a name, so the computer can say who did what.");
    app.prefs.set("deviceName", name).catch(() => {});
    controller = new AbortController();
    showProgress("Looking up the code…");
    try {
      const rec = await phone.pair({ origin: location.origin, code, deviceName: name, signal: controller.signal, onStep });
      const view = await app.addComputer(rec);
      showDone(view);
    } catch (e) {
      if (e.code === "aborted") return;
      showForm(e.message);
    } finally {
      controller = null;
    }
  };

  const onStep = (s) => {
    if (s.step === "hello") showProgress(`Found ${s.computerName}. Connecting…`);
    if (s.step === "commit") showProgress(`Waiting for ${s.computerName}…`);
    if (s.step === "compare") showCompare(s.computerName, s.comparison);
  };

  const cancel = () => {
    controller?.abort();
    showForm("");
  };

  function showForm(message) {
    error.textContent = message ?? "";
    fill(body,
      app.isIOS() && !app.isStandalone() && note("You're in Safari. If you'll use the app from your Home Screen, add it there first and pair from there: the Home Screen app keeps its own data.", "warn"),
      group({ header: "Pairing code", footer: "Tax Collector shows it on the computer: Guardian Settings, then Parents' phones, then Pair a Phone." },
        h("div", { class: "row code-row" }, codeInput)),
      group({ header: "Name for this phone", footer: "The student sees it when this phone does something, like “Mom's iPhone locked this Mac”." },
        fieldRow({ label: "Name", input: nameInput })),
      error,
      group({}, buttonRow({ text: "Pair", onClick: start, bold: true })));
  }

  function showProgress(text) {
    fill(body,
      group({}, h("div", { class: "row progress-row" }, spinner(text), h("span", { text }))),
      group({}, buttonRow({ text: "Cancel", onClick: cancel })));
  }

  function showCompare(computerName, comparison) {
    fill(body,
      h("div", { class: "compare" },
        h("p", { class: "compare-label", text: `Check that ${computerName} shows this number:` }),
        h("p", { class: "compare-code", text: lc.formatComparisonCode(comparison), attrs: { "aria-label": comparison.split("").join(" ") } })),
      group({ footer: "If the numbers are different, someone else's phone may be trying to pair. Choose It's Different on the computer, then start again." },
        h("div", { class: "row progress-row" }, spinner("Waiting"), h("span", { text: "Waiting for the parent at the computer to type the guardian code…" }))),
      group({}, buttonRow({ text: "Cancel", onClick: cancel })));
  }

  function showDone(view) {
    fill(body,
      h("div", { class: "compare" },
        h("p", { class: "compare-done", text: `Paired with ${view.rec.computerName}` }),
        h("p", { class: "compare-label", text: "This phone can now see homework and send commands. Pair the other parent's phone too, so either of you can remove a lost one." })),
      group({}, buttonRow({ text: "Open " + view.rec.computerName, onClick: () => app.replace("/c/" + encodeURIComponent(view.rec.id)), bold: true })));
  }

  showForm("");
  const el = screen({ title: "Pair a Computer", back: { label: "Computers", href: "#/" } }, body);
  return {
    el,
    live: false,
    cleanup: () => controller?.abort(),
    focus: () => (pending ? nameInput : codeInput).focus({ preventScroll: true }),
  };
}

/** replaceChildren, skipping the false and null that conditional parts leave. */
const fill = (el, ...children) => el.replaceChildren(...children.flat().filter((c) => c !== false && c !== null && c !== undefined));

function openFromHomeScreen(code) {
  return screen({ title: "Pair a Computer", back: { label: "Computers", href: "#/" } },
    note("On iPhone, pair from the app on your Home Screen, not from Safari. The Home Screen app keeps its own data."),
    group({ header: "Do this" },
      row({ title: "1. Tap the Share button at the bottom of Safari, then Add to Home Screen." }),
      row({ title: "2. Open Tax Collector from your Home Screen." }),
      row({ title: "3. Tap Pair a Computer and type this code:" }),
      h("div", { class: "row code-row" }, h("p", { class: "code-display", text: lc.formatPairingCode(code) }))));
}
