# Tax Collector

A Mac menu-bar app that holds you to your own deadlines. Add a task and a due date. Before the deadline, pay with proof: a screenshot, photo or file. Claude checks that the proof really shows the task done. If nothing is accepted by the deadline, every app except your allowed ones gets closed until you pay.

**[Download Tax Collector (.dmg)](https://github.com/Mr-Pythoneer/tax-collector/releases/latest/download/TaxCollector.dmg)** for Macs with Apple silicon (M1 or newer) and macOS 14 or later. It's the newest version; the steps to install it are [below](#install-from-the-disk-image) and inside the disk image, and so is [how to uninstall it](#uninstall).

**Allowed during a lock:** Arc, Claude, Word, Excel, PowerPoint, Outlook, OneNote, Teams, OneDrive, Mail, Zoom, VooV Meeting, Activity Monitor (plus Finder and a few system helpers).

## The task list

The main window lists what's due, soonest first, grouped by day (Overdue, Today, Tomorrow, then each date), like the Scheduled list in Reminders.

- **Classes:** Blackbaud and Teams assignments show their class under the title, with a coloured dot. Each class keeps its colour.
- **Notices:** problems show at the top of the list: the lock, a guardian unlock, proof checking not working, or Blackbaud or Teams import failing.
- **Below the list:** paid Blackbaud work waiting for its last check comes after the days. Finished tasks fold into **Completed**.
- **Repeating tasks:** in **New Task**, turn on **Repeats**. Choose **every N days** (1 is every day, 4 is every 4 days) or **every N weeks** on the days you pick (every week on Monday, every 2 weeks on Monday and Wednesday), plus the time and the day it starts. One copy is out at a time. The next appears once that copy's deadline has passed, even if you paid early, and a copy that's due needs its own proof like any task. If the Mac was off for weeks, only the next copy appears, not a pile of missed ones. **Stop Repeating** (in the **Repeating** section, or a copy's right-click menu) ends it; the copy that's out stays.
- **Details:** click a task (or right-click → **Show Details…**) to open it in its own window: what to do, the teacher's files and links for Blackbaud assignments, and your proof so far. It can stay open next to your work.

The app is light by default. **Appearance** in the menu bar menu switches to Dark or Match System.

## Rules

- **Proof** is checked by the local `claude` CLI, and a rejection means the task is still owed. Proof can be files, or a written account for things a file can't show, like a playing test. A written account is accepted only if it's specific and believable for the task.
- **While Claude checks** (usually under a minute), closing the window doesn't stop the check. **Cancel Check** takes the proof back: it counts for nothing and the task stays due. A proof sent before the deadline holds the lock off while it's checked, but for 5 minutes past the deadline at most, and checking it again after the deadline doesn't lift a lock.
- **Late proof** still unlocks you, after a late penalty: 30 more minutes locked by default.
- **Locked in at 24 hours.** You can change or delete a task until 24 hours before it's due. After that, only moving the deadline earlier is allowed. There is a 5-minute grace period after creating a task, for typos.
- **Guardian code.** A parent or friend sets it on first launch, and it is the only override. It can unlock for a while, excuse a task, approve a proof by hand, change a deadline, change the late penalty or the allowlist, or uninstall the app. Wrong codes back off: after the third wrong code you wait 30 s, then 60 s, and so on.
- **Clock guard.** Winding the clock back doesn't move you back before a deadline.
- **Asking for more time.** Before a deadline, you can ask Claude for up to 12 more hours. It grants time only for a real obstacle (being sick, a family event, a broken computer), never for "I didn't have time", and never more than you asked. The app enforces the limits whatever Claude says:
  - you need at least 5 finished tasks in the last 30 days, with at least 80% on time;
  - one request per task;
  - at most 2 extensions a week;
  - only before the deadline, so it can't end a lock that's already started.

  Your guardian can turn this off.

## Parents' phones

Parents can follow homework and control the Mac from their phones, through a small relay server the family runs on its own always-on computer (a mini PC). Everything between the Mac and a phone is encrypted, and only a parent's phone can sign a command, so neither the server nor the student can read the messages or fake one.

- **What a phone can do:**
  - lock the Mac now (until a time or until lifted; homework apps open, or everything closed), unlock it until a time, or go back to the usual rules;
  - add, edit, delete or excuse tasks, and set up repeating tasks;
  - approve a specific proof;
  - block apps (closed whenever they open, locked or not) or allow them during locks;
  - change the late penalty, turn asking for more time on or off, send the student a message, and remove a lost phone.

  Every action shows on the Mac as a notification naming the phone.
- **What a phone sees:** tasks and proof results, what's blocked, recent activity, and warnings that something got around Tax Collector:
  - test mode turned on;
  - the background agent removed;
  - the guardian code or the rules edited while the app wasn't running;
  - time the app wasn't running;
  - the clock changed;
  - a forged command.

  Never files, passwords or the guardian code.
- **Pairing** happens at the Mac, with the guardian code:
  1. Open Guardian Settings → **Parents' phones** → **Pair a Phone…**. The Mac shows a code.
  2. The parent opens the server's address on their phone, adds it to the Home Screen, and types the code there.
  3. Both screens show the same 6-digit number. The guardian code then confirms the match. This way, nobody else's phone can slip in, not even through the server.
- **While a phone is paired**, a missing guardian code doesn't bring back first-time setup: the Mac says to ask a parent, who can allow a new code from their phone.

Setting up the server: [`server/README.md`](server/README.md). The phone app: [`parent/README.md`](parent/README.md). The protocol: [`docs/parent-link-v1.md`](docs/parent-link-v1.md).

## Windows

[`windows/`](windows/) has Tax Collector for Windows: a tray app in C# on .NET 10, with the same rules, proof checking, a lock that closes apps by checking who made them (not just their file names), and a watchdog that restarts it if it's killed. Its checks pass on the Mac, and it builds for both Windows on ARM and regular PCs. It still needs testing on Windows itself; [`windows/VM-SETUP.md`](windows/VM-SETUP.md) sets up the test VM. Its parent link has the encryption and command checks so far; the network part comes after the VM tests.

## Install from the disk image

[Download TaxCollector.dmg](https://github.com/Mr-Pythoneer/tax-collector/releases/latest/download/TaxCollector.dmg). That link always gets the newest version; older ones are on the [Releases page](https://github.com/Mr-Pythoneer/tax-collector/releases). It needs a Mac with Apple silicon and macOS 14 or later.

1. **Copy it:** drag Tax Collector into Applications.
2. **Get past macOS's warning:** the app isn't notarized (that needs a paid Apple developer account), so the first time you open it, macOS refuses. Click Done, then go to System Settings → Privacy & Security and click **Open Anyway**.
3. **Finish setup:** read the welcome screen, have the guardian set their code, and click **Finish Setup**. If the app was opened from somewhere else, it copies itself into Applications first. Then it sets itself to run in the background and at every login. No Terminal needed.

**Proof checking** needs Claude Code, signed in once:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude auth login
```

`./scripts/make-dmg.sh` builds the disk image as `build.noindex/TaxCollector.dmg`, with `Resources/How to Install.txt` inside it. Build output goes in `build.noindex/` so Spotlight lists only the installed app.

To publish a version, attach that file to a GitHub release (`gh release create v<version> build.noindex/TaxCollector.dmg`). Keep the name `TaxCollector.dmg`: the download link at the top of this page asks for that name from the latest release.

## Uninstall

Uninstalling makes things easier on you, so like every other way out it takes the guardian code. It works during a lock too.

1. Open **Guardian…** from the menu bar icon (or the **Guardian** button in the main window, or on the lock screen) and enter the code.
2. Under **Maintenance**, click **Uninstall Tax Collector…**, then **Uninstall**.

Tax Collector stops, no longer starts at login, and moves itself to the Trash. Your tasks and proofs stay in `~/Library/Application Support/TaxCollector`, in case you reinstall.

**To remove everything,** including the saved Blackbaud sign-in and the Claude token, delete what it leaves behind:

```bash
rm -rf "$HOME/Library/Application Support/TaxCollector" \
       "$HOME/Library/WebKit/io.github.mrpythoneer.taxcollector" \
       "$HOME/Library/HTTPStorages/io.github.mrpythoneer.taxcollector.binarycookies" \
       "$HOME/Library/Caches/io.github.mrpythoneer.taxcollector" \
       "$HOME/Library/Logs/TaxCollector.log"
defaults delete io.github.mrpythoneer.taxcollector
```

Without Terminal, use **Go → Go to Folder…** in Finder to open each of those folders and drag the Tax Collector items to the Trash.

**Lost the guardian code?** When nothing is locked, you can remove it from Terminal instead (during a lock, Terminal gets closed):

```bash
launchctl bootout "gui/$(id -u)/io.github.mrpythoneer.taxcollector"
rm "$HOME/Library/LaunchAgents/io.github.mrpythoneer.taxcollector.plist"
```

Then drag Tax Collector from Applications to the Trash. If you built it from source, `./scripts/uninstall.sh` does all of this; add `--purge` to delete your tasks and proofs too.

## Build and install

Command Line Tools are enough; Xcode isn't needed.

```bash
./scripts/install.sh      # builds arm64, copies to ~/Applications, starts at login (LaunchAgent, KeepAlive)
./scripts/uninstall.sh    # add --purge to delete tasks and proofs too
swift run taxcore-check   # logic checks (lock rule, edit window, clock guard, guardian hash, auditor parsing, iCal parser, Blackbaud and Teams sync)
```

To try the install without touching the real one, set `TAXCOLLECTOR_LABEL` and `TAXCOLLECTOR_DEST` for `install.sh` and `uninstall.sh`. Other `TAXCOLLECTOR_*` variables are passed to the installed copy.

The app icon is generated by `swift scripts/make-icon.swift`.

### Auditor sign-in

The proof check runs `claude -p` in the background, so the CLI must be signed in. Do one of these in Terminal:

- `claude auth login`
- `claude setup-token`, then paste the token in **Tax Collector → Auditor**. This token lasts about a year.

### Test mode

```bash
TAXCOLLECTOR_DATA_DIR=/tmp/tc-test TAXCOLLECTOR_DRY_RUN=1 "build.noindex/Tax Collector.app/Contents/MacOS/TaxCollector"
```

- `TAXCOLLECTOR_DATA_DIR` uses separate data and skips the single-instance check.
- `TAXCOLLECTOR_DRY_RUN=1` logs which apps would be closed instead of closing them, and lets you quit normally. So does `TAXCOLLECTOR_ALLOW_QUIT=1`.
- `TAXCOLLECTOR_ENFORCE_ONLY=com.apple.TextEdit,com.apple.calculator` makes a real lock close only those apps. This lets you test real closing without losing anything else you have open.
- `TAXCOLLECTOR_SELFTEST=1` runs every feature through the app's own code with a fake Claude, a fake Blackbaud and a fake Teams. It writes `selftest.txt` and quits. Always use it with a throwaway `TAXCOLLECTOR_DATA_DIR`.
- `TAXCOLLECTOR_TEST_SHEET=new|edit|proof|lastcheck|extend|details|guardian|blackbaud|auditor|log|lock`, optionally followed by `:part of a task title`, opens that screen at launch for screenshots.
- `TAXCOLLECTOR_TEST_QUIET=1` shows nothing at all (no windows, menu bar icon or notifications), for scripted tests.
- `TAXCOLLECTOR_PARENT_SERVER` and `TAXCOLLECTOR_PARENT_SETUP` link a test copy to a relay. `TAXCOLLECTOR_TEST_PAIR=1` starts pairing and writes the code to `pairing-code.txt`, and `TAXCOLLECTOR_TEST_PAIR_AUTOCONFIRM=1` approves without the guardian code. `scripts/parent-link-e2e.sh` uses them: it runs the relay in `server/`, a quiet test copy and a fake phone (`scripts/fake-phone.mjs`) through every command, a replayed command and a forged signature.
- `TAXCOLLECTOR_TEST_REPEAT=days:4` (or `weeks:2`) opens New Task with that repeat already filled in.
- `TAXCOLLECTOR_TEST_SNAPSHOT=/path/to.png` with `TAXCOLLECTOR_TEST_SHEET` draws that screen into a PNG without showing any window or menu bar icon, then quits, so a screen can be checked while someone is using the Mac.
- `TAXCOLLECTOR_TEST_DETAILS_JSON=/path/to/page.json` makes every assignment's details window show that saved `UserAssignmentDetailsGetAllStudentData` answer instead of asking Blackbaud.
- `TAXCOLLECTOR_TEST_GUARDIAN_CODE` types a guardian code into the code box. It still has to be the right code.
- Setup is never run in a test like this unless you add `TAXCOLLECTOR_TEST_SETUP=1`. With it, `TAXCOLLECTOR_TEST_APPLICATIONS_DIR` stands in for the Applications folder, and `TAXCOLLECTOR_LABEL` names the background copy. Launching with `--finish-setup` acts like clicking Finish Setup.
- `TAXCOLLECTOR_TEAMS_PROBE=1` signs in to Teams if needed (a window opens), then writes `teams-probe.json`: how many assignments Teams lists as owed and which would become tasks. It imports nothing. It also writes `teams-debug.json` (where each page is, with no addresses beyond host and path and nothing from its content) while it waits. Start it with `open -n --env …` so its windows can come to the front.
- `TAXCOLLECTOR_TEST_TEAMS_JSON=/path/to/work.json` makes Teams import read a saved `/edu/me/work` answer instead of signing in.
- `TAXCOLLECTOR_BLACKBAUD_PROBE=1` opens the Blackbaud sign-in if needed, then writes `blackbaud-probe.json`: a read-only report of what Blackbaud's endpoints return, which assignment each imported task matches, and what one assignment's page holds (counts only). It saves only the fields the app uses, never cookies or tokens. Run this first when Blackbaud changes something.
- `TAXCOLLECTOR_TEST_LAST_CHECK=<part of a title>` opens that paid task's last check, ticks everything and confirms it, just as your clicks would. **This really marks the assignment Completed in Blackbaud.**
- To test Blackbaud import without a real feed, put `"blackbaudURL": "file:///path/to/sample.ics"` in that folder's `settings.json`. The app polls it at launch.

## Teams import

Tax Collector can import your Microsoft Teams assignments (the Assignments app) as tasks, alongside or instead of Blackbaud. Open **Tax Collector → Teams** (or the person-group button in the toolbar) and click **Sign In and Turn On Import**. A window opens with Microsoft's own sign-in for your school account; tick **Stay signed in** so you don't need to do it again. Tax Collector never sees your password. The window closes by itself once it works.

**How it reads Teams.** There's no official way for a student to do this: Microsoft's assignments API needs a school administrator's consent. So Tax Collector does what you do in a browser. It opens the Teams web app in a hidden window, lets Teams open its Assignments app, and asks that app's own server for your list, with the sign-in the app already has. It only ever *reads*: it never hands anything in, marks anything done or changes anything in Teams. The sign-in token stays inside the page; Tax Collector only receives the answers.

**How it imports**

- Teams is checked every 30 minutes (and again after 5 minutes if a check failed), or when you click **Sync Now**. The check takes about 15 seconds.
- An assignment becomes a task if it's still assigned, not handed in or returned, not excused, and due from now on. Its title is `Class: Assignment`, so the class shows and gets its colour like a Blackbaud one. The teacher's instructions are the task's description, and **Open in Teams** is in its details window.
- A task is matched by Teams' own assignment ID, so a re-check never makes duplicates, and a deleted one isn't imported again.
- A teacher's change follows the same lock-in rule as for Blackbaud: anything before the task is locked in, only an earlier deadline after, and never a deadline in the past.
- Work that drops off the list (you handed it in on Teams, or the teacher removed it) stays as a task. Handing in on Teams doesn't finish the task here: you still submit proof to Tax Collector.
- Turning import on never needs the guardian. Turning it off does while anything it imported is due within 24 hours (or later, with 5 minutes' grace after turning it on).
- If the Microsoft sign-in lapses, a notice at the top says so, and **Sign In Again** brings the window back.

**Fragile on purpose.** This relies on how Microsoft's web apps work today (the Assignments app's address, its sign-in audience and the Assignments button in Teams). If Microsoft changes any of them, import stops with an error rather than guessing. The parts to fix are kept together in `Sources/TaxCore/Teams.swift` (addresses and reading) and `Sources/TaxCollector/TeamsLink.swift` (the page).

## Inbox for other tools

Other programs on this Mac can hand Tax Collector a task by dropping a small JSON file into `~/Library/Application Support/TaxCollector/inbox/`. Tax Collector checks the folder every few seconds, turns each good file into an ordinary task, and deletes the file.

```json
{"v": 1, "id": "my-tool:2026-10-21:1", "title": "Read chapter 4", "details": "Optional notes", "due": "2026-10-28T17:00:00Z", "from": "My Tool"}
```

- `id` is the sender's own name for the item. Sending the same `id` again never adds a second task, even after a restart.
- `due` is an ISO 8601 date-time. It must be in the future and within 120 days; titles are at most 200 characters; files over 20 KB are refused.
- An imported task follows every normal rule: you can edit or delete it until 24 hours before it's due, and it needs proof like any other.
- A file that can't be used is moved to `inbox/rejected/`, named with the reason, and the reason goes in the event log. At most 20 files are read per check.

## Data

Everything lives in `~/Library/Application Support/TaxCollector/`:

- `tasks.json` and `settings.json` (which holds the Blackbaud feed link)
- `recurring.json`, which holds your repeating tasks and when each one's current copy is due
- `blackbaud.json`, which holds what the feed last said about each imported assignment and which ones you deleted
- `blackbaud-session.plist`, which holds your Blackbaud sign-in so it survives restarts. It's readable only by your account, and **Sign out** deletes it.
- `teams.json`, which holds what Teams last said about each imported assignment and which ones you deleted
- `teams-session.plist`, which holds your Microsoft sign-in cookies so Teams import survives restarts. It's readable only by your account, and **Sign Out of Teams** deletes it.
- `guardian.json`, which holds only a salted PBKDF2 hash of the code
- `parent-link.json`, which holds the server's address and setup code, this Mac's keys, and the paired phones. It's readable only by your account. A copy is kept in the app's preferences, so if the file is deleted, it comes back and the phones are told.
- `proofs/<task>/<submission>/`, which holds your files plus the auditor's raw answer
- `inbox/`, where other tools drop tasks (see above)
- `events.log`

## Honest limits

This is self-accountability, not parental-control software.

- **Before a lock starts**, you could still turn it off: `launchctl bootout`, editing the JSON, or switching it off in System Settings → Login Items.
- **During a lock**, Terminal, System Settings and text editors are closed, so those routes are blocked.
- **Activity Monitor:** a plain Quit is refused. Force Quit works, but launchd restarts the app within about 2 seconds.
- **With parents' phones paired**, these routes don't go unnoticed. The phones see when the app stops reporting, and when it restarts after its files or rules were changed. But someone who controls the server, or rebuilds the app, can still get around it. And it can't block websites: Arc stays open during a lock, and so does everything in it.

## Blackbaud import

Tax Collector can import assignments from Blackbaud (`yourschool.myschoolapp.com`) as tasks.

**Get the link.** In Assignment Center, switch to the calendar view, open the menu next to it and choose **Share calendar**. Older versions have a feed icon that looks like the Wi-Fi symbol instead. Copy the link. It starts with `webcal://` and contains `/podium/feed/iCal.aspx?z=…`. Then paste it in **Tax Collector → Blackbaud** and click **Check Link**. You see what would be imported before anything is.

- Use the Assignment Center feed, not the whole calendar's. The calendar feed also has class periods and school events, and each of those would become a task.
- The Assignment Center feed only covers the next 60 days, and Blackbaud can take up to an hour to show changes.
- Anyone with the link can read your calendar. It's kept in `settings.json` and never written to the log.

**How it imports**

- The feed is checked every 30 minutes, and again 5 minutes after a failed check. Each assignment becomes a task, matched by the event's UID, so a re-check never makes duplicates.
- Assignments already past due aren't imported.
- Most assignments have a date but no time. By default they're due at **10 PM the evening before**, because homework is usually due when class starts. You can change this in the Blackbaud window, either to a different time or to a time on the due date itself.
- If a teacher changes an assignment, the task changes too, under the same lock-in rule as your own edits. Before it's locked in, anything can change. After that, only an earlier deadline gets through. A deadline is never moved into the past.
- If you've edited an imported task, your edit stays until the teacher changes that assignment again.
- Assignments that drop out of the feed stay as tasks, because the feed only looks ahead.

**Rules**

- Turning import on makes things stricter, so it never needs the guardian code.
- Deleting an imported task follows the usual 24-hour rule. A deleted assignment isn't imported again.
- Turning import off follows the same rule. It's free unless something it imported is locked in (due within 24 hours, or still in a late penalty), or within 5 minutes of turning it on. Otherwise only the guardian can turn it off. Tasks it already imported stay either way.

### Last check and marking Completed

Blackbaud never needs anything submitted, but its Assignment Center has a To do / In progress / Completed status. Tax Collector can set it for you:

1. **Sign in once.** Go to **Tax Collector → Blackbaud → Sign in to Blackbaud**. The sign-in happens on Blackbaud's own page, or your school's Google or Microsoft page, so Tax Collector never sees your password. The session stays in the app's web storage.
2. **Pay with proof as usual.** While the auditor checks your proof, it also turns the assignment's description into a checklist of everything it asks for.
3. **Do the last check.** Once the proof is accepted, tick every item, then press **I've done all of this**.
4. **Tax Collector marks it Completed.** It finds the assignment in Blackbaud by course, title and due date, since the feed carries no assignment ID. It goes by the date Blackbaud has, so a deadline your guardian moved still finds its assignment. It sets the status to Completed and reads it back to confirm. If that fails, the task shows the reason and a Retry button.

This uses the same private web endpoints the Blackbaud student site uses (`/api/assignment2/assignmentstatusupdate` and the Assignment Center list). Blackbaud changes them now and then, so they're kept together in `Sources/TaxCollector/BlackbaudAPI.swift`.

### Assignment details

Click an imported assignment to see what its page in Blackbaud shows:

- **What to do:** the teacher's full instructions, with their links, bold and lists. The calendar feed only has a short version, which shows until the page loads.
- **The teacher's files:** **Open** downloads one with your Blackbaud sign-in into your Downloads folder, the way a browser would, then opens it. Opening it again reuses that copy. If a file won't download, it opens in the browser instead.
- **Links,** the assignment type and points, and **Open in Blackbaud** for the page itself.

This needs the same Blackbaud sign-in as the last check; signed out, the window says so and offers **Sign In to Blackbaud…**, then loads by itself once you're in. During a lock, anything that would open in an app that isn't allowed (Preview, another browser) opens in Arc instead. The page comes from `/api/assignment2/UserAssignmentDetailsGetAllStudentData`, read-only.
