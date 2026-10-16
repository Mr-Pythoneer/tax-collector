import SwiftUI
import TaxCore

enum Sheet: Identifiable, Equatable {
    case newTask
    case edit(UUID)
    case proof(UUID)
    case guardian
    case log
    case auditor
    case lastCheck(UUID)
    case blackbaud

    var id: String {
        switch self {
        case .newTask: "new"
        case let .edit(id): "edit-\(id)"
        case let .proof(id): "proof-\(id)"
        case .guardian: "guardian"
        case .log: "log"
        case .auditor: "auditor"
        case let .lastCheck(id): "last-check-\(id)"
        case .blackbaud: "blackbaud"
        }
    }
}

/// Lets the menu bar ask a window to show a sheet.
@MainActor
@Observable
final class Router {
    var mainSheet: Sheet?
    var lockSheet: Sheet?
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var openLockWindow: () -> Void

    var body: some View {
        @Bindable var router = router
        Group {
            if model.guardian == nil {
                OnboardingView()
            } else {
                TaskListView(openLockWindow: openLockWindow)
            }
        }
        .frame(minWidth: 540, minHeight: 460)
        .sheet(item: $router.mainSheet) { sheet in
            SheetContent(sheet: sheet, dismiss: { router.mainSheet = nil },
                         present: { router.mainSheet = $0 })
        }
    }
}

/// Everything you owe, soonest first and grouped by day, like Reminders' Scheduled list.
struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let openLockWindow: () -> Void
    @State private var showCompleted = false

    var body: some View {
        Group {
            if model.tasks.isEmpty && notices.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "checklist")
                } description: {
                    Text("Add a task with a due date, or import your assignments from Blackbaud.")
                } actions: {
                    Button("New Task") { router.mainSheet = .newTask }
                    Button("Import from Blackbaud…") { router.mainSheet = .blackbaud }
                }
            } else {
                list
            }
        }
        .navigationTitle("Tax Collector")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.mainSheet = .newTask
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("New task")
            }
            ToolbarItem {
                Button {
                    router.mainSheet = .blackbaud
                } label: {
                    Label("Blackbaud", systemImage: "graduationcap")
                }
                .help("Blackbaud import")
            }
            ToolbarItem {
                Button {
                    router.mainSheet = .guardian
                } label: {
                    Label("Guardian", systemImage: "person.badge.key")
                }
                .help("Guardian settings")
            }
        }
    }

    private var subtitle: String {
        let owed = model.tasks.filter(\.isPending)
        let overdue = owed.filter { $0.dueDate <= model.now }.count
        let today = owed.filter { $0.dueDate > model.now && Calendar.current.isDate($0.dueDate, inSameDayAs: model.now) }.count
        var parts: [String] = []
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if today > 0 { parts.append("\(today) due today") }
        if parts.isEmpty { parts.append(owed.isEmpty ? "Nothing due" : "\(owed.count) to do") }
        if model.dryRun { parts.insert("Test mode", at: 0) }
        return parts.joined(separator: " · ")
    }

    private var list: some View {
        let sections = Agenda.sections(model.tasks, now: model.now)
        let finishUp = model.tasks.filter { $0.needsLastCheck || $0.blackbaudMarkFailed }
        let completed = model.settledTasks.filter { task in !finishUp.contains { $0.id == task.id } }
        return List {
            if !notices.isEmpty {
                Section {
                    ForEach(notices) { NoticeRow(notice: $0) }
                }
            }
            if sections.isEmpty {
                Section {
                    Text("Nothing due.").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.tasks) { TaskRow(task: $0, showsDate: !section.isDay) }
                } header: {
                    SectionHeader(kind: section.kind)
                }
            }
            if !finishUp.isEmpty {
                Section {
                    ForEach(finishUp) { TaskRow(task: $0, showsDate: true) }
                } header: {
                    Text("Waiting for Last Check").font(.headline).foregroundStyle(.primary)
                }
            }
            if !completed.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        ForEach(completed.prefix(50)) { CompletedRow(task: $0) }
                    } label: {
                        Text("Completed (\(completed.count))").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Problems worth seeing before the tasks: the lock, a guardian unlock, proof checking or the feed not working.
    private var notices: [Notice] {
        var out: [Notice] = []
        if model.lock.isLocked {
            out.append(Notice(id: "lock", symbol: "lock.fill", color: .red, title: "Your Mac is locked",
                              detail: model.lock.overdue.isEmpty
                                  ? "Late penalty. It unlocks by itself when the time is up."
                                  : "Other apps will close until the overdue tasks below have proof.",
                              button: "Show", action: openLockWindow))
        } else if let until = model.lock.overrideUntil {
            out.append(Notice(id: "override", symbol: "key.fill", color: .orange,
                              title: "Unlocked by your guardian until \(Fmt.time.string(from: until))",
                              detail: "Anything still overdue then locks the Mac again.", button: nil, action: {}))
        }
        if model.auditorStatus != "Ready" && model.auditorStatus != "Checking…" {
            let open: () -> Void = { router.mainSheet = .auditor }
            out.append(Notice(id: "auditor", symbol: "exclamationmark.triangle.fill", color: .orange,
                              title: "Proof checking isn't working",
                              detail: "Claude can't check proof right now (\(model.auditorStatus.lowercased())).",
                              button: "Fix…", action: open))
        }
        if let error = model.feedError {
            let open: () -> Void = { router.mainSheet = .blackbaud }
            out.append(Notice(id: "feed", symbol: "exclamationmark.triangle.fill", color: .orange,
                              title: "Blackbaud import failed", detail: error, button: "Open…", action: open))
        }
        return out
    }
}

struct Notice: Identifiable {
    let id: String
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void
}

struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).fontWeight(.semibold)
                Text(notice.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let button = notice.button {
                Button(button, action: notice.action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SectionHeader: View {
    let kind: AgendaSection.Kind

    var body: some View {
        Group {
            switch kind {
            case .lateFee:
                Text("Late Penalty").foregroundStyle(.red)
            case .overdue:
                Text("Overdue").foregroundStyle(.red)
            case let .day(day):
                if let name = Self.relativeName(day) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(name).foregroundStyle(.primary)
                        Text(Fmt.formatted(day, "EEEEMMMMd")).foregroundStyle(.secondary).fontWeight(.regular)
                    }
                } else {
                    Text(Fmt.formatted(day, "EEEEMMMMd")).foregroundStyle(.primary)
                }
            }
        }
        .font(.headline)
        .textCase(nil)
    }

    private static func relativeName(_ day: Date) -> String? {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return nil
    }
}

extension AgendaSection {
    var isDay: Bool {
        if case .day = kind { return true }
        return false
    }
}

extension TaxTask {
    var blackbaudMarkFailed: Bool {
        if case .failed = blackbaudMark { return true }
        return false
    }

    var isExcused: Bool {
        if case .excused = status { return true }
        return false
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask
    /// Day sections already show the date, so rows there show only the time.
    let showsDate: Bool

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
                HStack(spacing: 5) {
                    Text(parts.title).fontWeight(.medium)
                    if task.isPending && model.isFrozen(task) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Due within 24 hours, so it can't be changed or deleted without your guardian.")
                    }
                }
                if let course = parts.course {
                    Text(course).font(.caption).foregroundStyle(.secondary)
                }
                if !task.details.isEmpty {
                    Text(task.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                notes(latest: latest)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(showsDate ? Fmt.dateTime.string(from: task.dueDate) : Fmt.time.string(from: task.dueDate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(task.isPending ? task.urgencyColor(now: model.now) : .secondary)
                timing
            }
            action(isChecking: isChecking)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if task.isPending { Button("Edit…") { router.mainSheet = .edit(task.id) } }
            Button("Delete", role: .destructive) {
                if model.delete(task.id) == .needsGuardian { router.mainSheet = .guardian }
            }
        }
    }

    @ViewBuilder
    private func notes(latest: ProofSubmission?) -> some View {
        if let latest, task.isPending, latest.verdict == .rejected {
            Label("Proof not accepted: \(latest.reason)", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let latest, task.isPending, latest.verdict == .error {
            Label("Proof couldn't be checked: \(latest.reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
        if task.needsLastCheck {
            Text("Proof accepted. Do the last check to mark it complete in Blackbaud.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if case let .failed(reason) = task.blackbaudMark {
            Label("Couldn't mark it complete in Blackbaud: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var timing: some View {
        if task.isPending {
            Text(Fmt.relative(task.dueDate, now: model.now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(task.dueDate <= model.now ? Color.red : Color.secondary)
        } else if case let .provenLate(_, end) = task.status, end > model.now {
            Text("unlocks in \(Fmt.span(end.timeIntervalSince(model.now)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.red)
        } else {
            let (word, color) = task.statusWord(now: model.now, checking: false)
            Text(word).font(.caption).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func action(isChecking: Bool) -> some View {
        if isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        } else if task.isPending {
            if task.dueDate <= model.now {
                Button("Submit Proof…") { router.mainSheet = .proof(task.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Submit Proof…") { router.mainSheet = .proof(task.id) }
                    .controlSize(.small)
            }
        } else if task.needsLastCheck {
            Button("Last Check…") { router.mainSheet = .lastCheck(task.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if task.blackbaudMarkFailed {
            Button("Try Again…") { router.mainSheet = .lastCheck(task.id) }
                .controlSize(.small)
        }
    }
}

/// A finished task: kept quiet so what's still due stays the focus.
struct CompletedRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask

    var body: some View {
        let parts = Agenda.courseAndTitle(task)
        let (word, color) = task.statusWord(now: model.now, checking: false)
        HStack(spacing: 8) {
            Image(systemName: task.isExcused ? "minus.circle" : "checkmark.circle.fill")
                .foregroundStyle(color)
            Text(parts.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if case .done = task.blackbaudMark {
                Image(systemName: "graduationcap.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Marked complete in Blackbaud")
            }
            Spacer()
            Text(word).font(.caption).foregroundStyle(color)
            Text(Fmt.formatted(task.dueDate, "MMMd"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                if model.delete(task.id) == .needsGuardian { router.mainSheet = .guardian }
            }
        }
    }
}

/// One place that maps a sheet to its view, shared by the main and lock windows.
struct SheetContent: View {
    let sheet: Sheet
    let dismiss: () -> Void
    let present: (Sheet) -> Void

    var body: some View {
        switch sheet {
        case .newTask: TaskEditorView(editing: nil, dismiss: dismiss, askGuardian: { present(.guardian) })
        case let .edit(id): TaskEditorView(editing: id, dismiss: dismiss, askGuardian: { present(.guardian) })
        case let .proof(id): ProofSubmitView(taskID: id, dismiss: dismiss)
        case .guardian: GuardianView(dismiss: dismiss)
        case .log: LogView(dismiss: dismiss)
        case .auditor: AuditorView(dismiss: dismiss)
        case let .lastCheck(id): LastCheckView(taskID: id, dismiss: dismiss)
        case .blackbaud: BlackbaudView(dismiss: dismiss, askGuardian: { present(.guardian) })
        }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Log").font(.title2.bold())
            ScrollView {
                Text(model.store.recentLog().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 440)
    }
}
