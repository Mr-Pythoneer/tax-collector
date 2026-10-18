import SwiftUI
import TaxCore

/// Shown while the Mac is locked: what's overdue, how to unlock it, and what got closed.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 16)
            List {
                if !model.lock.overdue.isEmpty {
                    Section("Overdue") {
                        ForEach(model.lock.overdue) { OverdueRow(task: $0) }
                    }
                }
                if !model.lock.penalties.isEmpty {
                    Section("Late Penalty") {
                        ForEach(model.lock.penalties) { PenaltyRow(task: $0) }
                    }
                }
                Section {
                    if !model.closedApps.isEmpty {
                        LabeledContent(model.dryRun ? "Would have closed" : "Closed",
                                       value: model.closedApps.joined(separator: ", "))
                    }
                    LabeledContent("Still allowed", value: allowedApps)
                }
                .font(.callout)
            }
            .listStyle(.inset)
            Divider()
            HStack {
                if model.dryRun {
                    Label("Test mode: nothing is actually closed.", systemImage: "testtube.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Guardian…") { router.lockSheet = .guardian }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, minHeight: 440)
        .sheet(item: $router.lockSheet) { sheet in
            SheetContent(sheet: sheet, dismiss: { router.lockSheet = nil }, present: { router.lockSheet = $0 })
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.lock.isLocked ? "This Mac is locked" : "Unlocked")
                    .font(.title2.bold())
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var explanation: String {
        if !model.lock.isLocked { return "Everything is open again. You can close this window." }
        if let parentLock = model.lock.parentLock {
            let until = parentLock.until.map { " until \(Fmt.time.string(from: $0))" } ?? " until they unlock it"
            let what = parentLock.strength == .all
                ? "Every app closes except Finder and Tax Collector."
                : "Apps other than the ones allowed below keep closing."
            let note = parentLock.note.map { " \u{201C}\($0)\u{201D}" } ?? ""
            return "\(parentLock.by) locked this Mac\(until). \(what)\(note)"
        }
        if !model.lock.overdue.isEmpty {
            let count = model.lock.overdue.count
            return "\(count == 1 ? "A task is" : "\(count) tasks are") overdue. Apps other than the ones allowed below will keep closing until you submit proof."
        }
        if let end = model.lock.penaltyEndsAt {
            return "Your proof was accepted, but it was late. The Mac unlocks at \(Fmt.time.string(from: end))."
        }
        return ""
    }

    private var allowedApps: String {
        if model.lock.strength == .all { return "None: a parent locked everything." }
        var names = Allowlist.apps.map(\.name)
        let extra = model.settings.extraAllowedBundleIDs.count
        if extra > 0 { names.append("\(extra) more added by your guardian") }
        return names.joined(separator: ", ")
    }
}

private struct OverdueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask

    var body: some View {
        let parts = Agenda.courseAndTitle(task)
        let latest = task.proofs.last
        let isChecking = latest.map { model.checking.contains($0.id) } ?? false
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.courseColor(for: task) ?? Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(parts.title).fontWeight(.medium)
                if let course = parts.course {
                    Text(course).font(.caption).foregroundStyle(.secondary)
                }
                Text("Was due \(Fmt.dateTime.string(from: task.dueDate)) (\(Fmt.relative(task.dueDate, now: model.now)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
                if let latest, latest.verdict == .rejected {
                    Text("Last proof wasn't accepted: \(latest.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button("Submit Proof…") { router.lockSheet = .proof(task.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .opensDetails(task.id)
        .contextMenu {
            Button("Show Details…") { model.onOpenDetails(task.id) }
            if isChecking, let latest {
                Button("Cancel Check") { model.cancelCheck(taskID: task.id, submissionID: latest.id) }
            }
        }
    }
}

private struct PenaltyRow: View {
    @Environment(AppModel.self) private var model
    let task: TaxTask

    var body: some View {
        HStack {
            Text(Agenda.courseAndTitle(task).title)
            Spacer()
            if case let .provenLate(_, end) = task.status {
                Text("\(Fmt.span(end.timeIntervalSince(model.now))) left")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
