# Parent app

A home-screen web app for parents: see homework status, lock or unlock the computer, manage tasks and repeating tasks, allow or block apps, change the late penalty, and send the student a message. The relay server in [`server/`](../server/) serves it, so it lives at the server's own address.

Protocol: [`docs/parent-link-v1.md`](../docs/parent-link-v1.md).

## Installing it on a phone

**iPhone:** open the server's address in Safari, tap **Share**, then **Add to Home Screen**, and open Tax Collector from the Home Screen. Pair from there, not from Safari: an app on the Home Screen keeps its own data, apart from Safari, so a pairing made in Safari doesn't carry over.

**Android:** open the address in Chrome and choose **Install app** (or **Add to Home screen**) from the menu. The computer's QR code works here: it opens the app with the code already filled in.

Then, on the computer, open Tax Collector's **Guardian Settings → Parents' phones → Pair a Phone**, and type the code it shows into **Pair a Computer** on the phone. Both screens then show the same 6-digit number; the parent at the computer checks it and types the guardian code. The phone never asks for the guardian code.

The server's address must never change after phones are paired: each phone's keys and data belong to that exact address.

## What's on each screen

| Screen | What it does |
|---|---|
| Computers | Every paired computer, with a one-line status. Pair another. |
| Pair a Computer | Type the code (or open the QR link), name this phone, compare the 6-digit number. |
| Status | In plain words: "Locked since 7:02 PM: Math worksheet overdue". How fresh the news is (from the server's clock), asleep or not heard from, and tamper warnings from the computer. |
| Lock or Unlock | Lock now until a time or until you unlock it, with homework apps or with everything closed; unlock until a time; back to the normal rules. |
| Tasks | Grouped like the Mac: Late Penalty, Overdue, then by day, then finished. Add, edit, delete, excuse. Approve one specific proof, with Claude's reason and the student's note beside it. |
| Repeating Tasks | Every N days, or every N weeks on chosen days. Add or stop. |
| Apps | Always blocked, and also allowed during locks. New ones are picked from the apps the computer has seen. |
| Rules | Late penalty, asking Claude for more time, and letting the computer set a new guardian code for 15 minutes. |
| Message the Student | A message that shows on the computer for 24 hours. |
| Activity | The computer's latest 100 events. |
| Phones | Remove another phone, or unpair this one. |

Every command shows where it is: **Sending…**, **Sent**, **Waiting: computer asleep**, **Delivered**, then **Applied**, **Nothing to change**, **Not supported**, or **Rejected** with the reason in words. Controls the computer doesn't support (its `capabilities`) are hidden.

## How it's built

Vanilla JavaScript modules, no build step, no outside scripts, fonts or images. The page follows the server's content security policy: no inline scripts or styles.

| File | |
|---|---|
| `js/linkcrypto.js` | The protocol's cryptography (WebCrypto, `CompressionStream`). Shared with the server's tests and fake clients. |
| `js/phone.js` | Pairing, sending commands, reading state. No storage of its own, so the fake phone runs the same code. |
| `js/db.js` | IndexedDB: paired computers (with their keys), counters, the last state, sent commands. |
| `js/format.js` | Words and times, in the computer's time zone. |
| `js/ui.js` | Grouped lists, the navigation bar, switches, sheets. |
| `js/app.js` | Routes, fetching state, following commands. |
| `js/screens/*.js` | One file per screen or group of screens. |
| `sw.js` | Network first, with the files kept for when the phone is offline. Never caches `/v1/`. |

Safety rules the code keeps:

- Text from the computer only goes onto the page as text (`textContent`), never as HTML. A test fails if any file uses `innerHTML` or the like.
- The link key and the signing key are non-extractable `CryptoKey`s in IndexedDB: the browser can use them, but no script can read them.
- The app asks the browser to keep its data (`navigator.storage.persist()`), and says so on the Computers screen if it won't.
- Commands go out one at a time per computer (`navigator.locks`), with a counter of `max(previous + 1, now in ms)` saved before sending. A "replayed" answer carries the computer's last counter, and the phone catches up to it.
- A state older than one already shown is ignored, so a server can't feed old news.
- Freshness is worked out from `serverTime − computerSeen`, never from the phone's or the computer's clock.

When you add a file, add it to `FILES` in `server/lib/static.mjs` and to `PRECACHE` in `sw.js`; a test checks the lists agree.

## Trying it without a Mac

```bash
node server/server.mjs
```

```bash
node server/tools/fake-computer.mjs --server http://localhost:8787 --setup-code <the code the server printed> --approve-delay 10
```

Open http://localhost:8787 in a browser, choose **Pair a Computer**, and type the code the fake computer prints. While it runs, type `sleep`, `wake`, `flag gap`, `reject not_found` or `remove <phone name>` into the fake computer to see how the app shows each case.
