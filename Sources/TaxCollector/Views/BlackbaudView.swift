import SwiftUI
import TaxCore

/// Connects a Blackbaud (myschoolapp) calendar feed. Turning it on never needs the guardian; turning it off can.
struct BlackbaudView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    let askGuardian: () -> Void

    @State private var link = ""
    @State private var checkingLink = false
    @State private var check: FeedCheck?
    @State private var blocked = false
    @State private var allDayTime = Date()
    @State private var dayBefore = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Blackbaud").font(Theme.title(20))
            if model.feedIsOn { connected } else { setup }
            Divider()
            allDaySection
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: load)
    }

    // MARK: Not connected

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import your assignments from Blackbaud as tasks. Tax Collector checks the feed every 30 minutes and adds anything new.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Sign in at your school's myschoolapp.com site and open Assignment Center.")
                Text("2. Switch to the calendar view, open the menu next to it and choose Share calendar. (Older versions have a feed icon that looks like the Wi-Fi symbol.)")
                Text("3. Copy the link. It starts with webcal:// and has /podium/feed/iCal.aspx in it.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("webcal://yourschool.myschoolapp.com/podium/feed/iCal.aspx?z=…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runCheck)
                Button("Check link", action: runCheck)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || checkingLink)
            }
            Text("Anyone with this link can read your Blackbaud calendar. It's saved only on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if checkingLink {
                ProgressView().controlSize(.small)
            } else if let check {
                checkResult(check)
            }
        }
    }

    @ViewBuilder
    private func checkResult(_ check: FeedCheck) -> some View {
        switch check {
        case let .bad(message):
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.stamp)
                .fixedSize(horizontal: false, vertical: true)
        case let .ok(url, upcoming, total):
            VStack(alignment: .leading, spacing: 6) {
                if upcoming.isEmpty {
                    Text("The feed works, but nothing in it is due from now on (\(total) item\(total == 1 ? "" : "s") in all).")
                } else {
                    Text("\(upcoming.count) upcoming assignment\(upcoming.count == 1 ? "" : "s") will become tasks:")
                }
                ForEach(upcoming.prefix(6), id: \.uid) { a in
                    HStack {
                        Text(a.title).lineLimit(1)
                        Spacer()
                        Text(Fmt.dateTime.string(from: a.dueDate)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if upcoming.count > 6 {
                    Text("and \(upcoming.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
                Text("If these look like class periods or school events rather than assignments, use the Assignment Center link instead. Turning import on doesn't need your guardian. Turning it off does while anything it imported is due within 24 hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Turn on import") {
                        model.startFeed(url)
                        self.check = nil
                        link = ""
                        blocked = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func runCheck() {
        let raw = link
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty, !checkingLink else { return }
        checkingLink = true
        check = nil
        Task {
            let result = await model.checkFeed(raw)
            checkingLink = false
            check = result
        }
    }

    // MARK: Connected

    private var connected: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap")
                Text("Importing from \(model.feedURL.map(Blackbaud.redacted) ?? "a link that can't be read")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.body.weight(.medium))
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(model.feedError == nil ? Color.secondary : Theme.stamp)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sync now") { model.syncFeed() }
                    .disabled(model.feedSyncing)
                if model.feedSyncing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Turn off import") {
                    blocked = model.stopFeed() == .needsGuardian
                }
            }
            if blocked {
                HStack {
                    Text("Something it imported is locked in, so turning it off needs your guardian.")
                        .foregroundStyle(Theme.stamp)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ask guardian…", action: askGuardian)
                }
                .font(.callout)
            }
            Divider()
            completionSection
            Text("Deleting an imported task follows the usual rule, and it won't be imported again. Assignments that leave the feed stay as tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Signing in lets Tax Collector tick assignments Completed after your last check.
    private var completionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mark assignments Completed").font(.headline)
            Text(model.blackbaudSignedIn
                 ? "Signed in. After your proof is accepted and you confirm the last check, Tax Collector marks the assignment Completed in Blackbaud."
                 : "Sign in once so Tax Collector can mark assignments Completed after your last check. You sign in on Blackbaud's own page; Tax Collector never sees your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.blackbaudSignedIn {
                    StampLabel(text: "SIGNED IN", color: Theme.paid)
                    Spacer()
                    Button("Sign out") { model.onBlackbaudSignOut() }
                } else {
                    Button("Sign in to Blackbaud…") { model.onBlackbaudSignIn() }
                        .disabled(model.feedURL?.isFileURL ?? true)
                }
            }
        }
    }

    private var statusLine: String {
        if let error = model.feedError { return error }
        let count = model.importedCount
        guard let last = model.blackbaud.lastSync else {
            return model.feedSyncing ? "Checking the feed…" : "Not synced yet."
        }
        return "Last synced \(Fmt.dateTime.string(from: last)) · \(count) imported task\(count == 1 ? "" : "s")"
    }

    // MARK: All-day assignments

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assignments with a date but no time").font(.headline)
            HStack {
                Text("Due at")
                DatePicker("Time", selection: $allDayTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("Day", selection: $dayBefore) {
                    Text("on the due date").tag(false)
                    Text("the evening before").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Apply") { model.setAllDayDue(minutes: chosenMinutes) }
                    .disabled(chosenMinutes == model.settings.allDayDueMinutes)
            }
            Text("An earlier time applies to everything. A later one only moves tasks that aren't locked in yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chosenMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: allDayTime)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return dayBefore ? minutes - 1440 : minutes
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let minutes = model.settings.allDayDueMinutes
        dayBefore = minutes < 0
        let local = dayBefore ? minutes + 1440 : minutes
        allDayTime = Calendar.current.date(bySettingHour: local / 60, minute: local % 60, second: 0, of: Date()) ?? Date()
    }
}
