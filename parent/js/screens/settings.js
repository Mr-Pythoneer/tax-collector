// Rules: the late penalty, asking for more time, and (if the computer allows it) letting it set
// a new guardian code.
import { group, row, toggleRow, buttonRow, screen, confirm } from "../ui.js";
import * as f from "../format.js";
import { nowOf, zone, can, backTo, problemNotes, waiting } from "./common.js";

const PENALTIES = [0, 15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720];

export function render({ app, view }) {
  if (!view.state) return { el: waiting(view, "Rules", app), live: true };
  const settings = view.state.settings ?? {};
  const current = settings.penaltyMinutes ?? 0;
  const options = PENALTIES.includes(current) ? PENALTIES : [...PENALTIES, current].sort((a, b) => a - b);
  const tz = zone(view);

  const allowSetup = async () => {
    const until = nowOf(view) + 15 * 60_000;
    const ok = await confirm({
      title: "Allow a new guardian code?",
      message: `For the next 15 minutes (until ${f.time(until, tz)}), the computer lets anyone there set a new guardian code. Only do this if the code was lost.`,
      ok: "Allow for 15 Minutes",
      tone: "tint",
    });
    if (ok) app.send(view, "allowGuardianSetup", { until });
  };

  const el = screen({ title: "Rules", back: backTo(view) },
    problemNotes(view, app),
    can(view, "penalty") && group({ header: "Late penalty", footer: "When work is turned in after its deadline, the computer stays locked this long once the proof is accepted." },
      options.map((m) => row({ title: m === 0 ? "No penalty" : f.duration(m), selected: m === current, onClick: m === current ? undefined : () => app.send(view, "setPenalty", { minutes: m }), className: "choice-row" }))),
    can(view, "extensions") && group({ footer: "The student can ask Claude for a few more hours on a task. Claude decides, and gives more to a good track record." },
      toggleRow({ title: "Asking for more time", checked: settings.extensionsEnabled !== false, onChange: (on) => app.send(view, "setExtensions", { enabled: on }) })),
    can(view, "guardianSetup") && group({ header: "Guardian code", footer: "If the guardian code was lost or its file deleted, the computer shows “Ask a parent” instead of setting up a new one. This opens that for 15 minutes." },
      buttonRow({ text: "Allow a New Guardian Code", onClick: allowSetup })));
  return { el, live: true };
}
