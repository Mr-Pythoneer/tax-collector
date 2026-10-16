import SwiftUI
import TaxCore

enum Sheet: Identifiable, Equatable {
    case newTask
    case edit(UUID)
    case proof(UUID)
    case guardian
    case log
    case auditor
    case blackbaud

    var id: String {
        switch self {
        case .newTask: "new"
        case let .edit(id): "edit-\(id)"
        case let .proof(id): "proof-\(id)"
        case .guardian: "guardian"
        case .log: "log"
        case .auditor: "auditor"
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
                ledger
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .sheet(item: $router.mainSheet) { sheet in
            SheetContent(sheet: sheet, dismiss: { router.mainSheet = nil },
                         present: { router.mainSheet = $0 })
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            if model.lock.isLocked {
                lockedBar
            } else if let until = model.lock.overrideUntil {
                infoBar("Guardian unlock until \(Fmt.time.string(from: until)). The debts are still owed.",
                        color: Theme.amber)
            }
            Divider()
            if model.tasks.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tax Collector").font(Theme.title(28))
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.dryRun { StampLabel(text: "DRY RUN", color: Theme.amber) }
        }
    }

    private var statusLine: String {
        let owed = model.tasks.filter(\.isPending)
        if owed.isEmpty { return "Nothing owed. Add a task to put yourself on the hook." }
        if let next = model.nextDue {
            return "\(owed.count) owed · next: \(next.title), \(Fmt.due(next, now: model.now))"
        }
        return "\(owed.count) owed"
    }

    private var lockedBar: some View {
        HStack {
            Image(systemName: "lock.fill")
            Text("You're locked until you pay what you owe.")
            Spacer()
            Button("Pay up…", action: openLockWindow)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Theme.stamp)
    }

    private func infoBar(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(color.opacity(0.15))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("The ledger is empty.").font(Theme.title(18))
            Text("Add a task and a due date. If you can't prove it's done by then,\nevery app except your allowed ones gets closed until you pay up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("New task…") { router.mainSheet = .newTask }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List {
            if !model.pendingTasks.isEmpty {
                Section("Owed") {
                    ForEach(model.pendingTasks) { TaskRow(task: $0) }
                }
            }
            if !model.settledTasks.isEmpty {
                Section("Settled") {
                    ForEach(model.settledTasks.prefix(30)) { TaskRow(task: $0) }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Button {
                router.mainSheet = .newTask
            } label: {
                Label("New task", systemImage: "plus")
            }
            .keyboardShortcut("n")
            Spacer()
            Button("Auditor: \(model.auditorStatus)") { router.mainSheet = .auditor }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(model.auditorStatus == "Ready" ? Theme.paid : Theme.stamp)
            Button("Blackbaud") { router.mainSheet = .blackbaud }
                .foregroundStyle(model.feedError == nil ? Color.primary : Theme.stamp)
                .help(model.feedError ?? (model.feedIsOn ? "Importing assignments from Blackbaud" : "Import assignments from Blackbaud"))
            Button("Log") { router.mainSheet = .log }
            Button("Guardian…") { router.mainSheet = .guardian }
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask

    var body: some View {
        let latest = task.proofs.last
        let isChecking = latest.map { model.checking.contains($0.id) } ?? false
        let (stampText, stampColor) = task.stamp(now: model.now, checking: isChecking)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.body.weight(.medium))
                    if case .blackbaud = task.source {
                        Image(systemName: "graduationcap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Imported from Blackbaud")
                    }
                    if model.isFrozen(task) && task.isPending {
                        Image(systemName: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Locked in: less than 24 hours to go. Only your guardian can change it.")
                    }
                }
                if !task.details.isEmpty {
                    Text(task.details).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(task.isPending && task.dueDate <= model.now ? Theme.stamp : .secondary)
                if let latest, latest.verdict == .rejected || latest.verdict == .error, task.isPending {
                    Text("Last proof \(latest.verdict == .rejected ? "rejected" : "failed"): \(latest.reason)")
                        .font(.caption)
                        .foregroundStyle(Theme.stamp)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StampLabel(text: stampText, color: stampColor)
                if task.isPending {
                    Button("Pay with proof…") { router.mainSheet = .proof(task.id) }
                        .controlSize(.small)
                        .disabled(isChecking)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if task.isPending { Button("Edit…") { router.mainSheet = .edit(task.id) } }
            Button("Delete", role: .destructive) {
                if model.delete(task.id) == .needsGuardian { router.mainSheet = .guardian }
            }
        }
    }

    private var subtitle: String {
        let due = Fmt.dateTime.string(from: task.dueDate)
        switch task.status {
        case .pending: return "\(due) · \(Fmt.due(task, now: model.now))"
        case let .proven(at): return "Paid \(Fmt.dateTime.string(from: at)) · was due \(due)"
        case let .provenLate(at, end):
            if end > model.now { return "Paid late \(Fmt.time.string(from: at)) · late fee ends in \(Fmt.span(end.timeIntervalSince(model.now)))" }
            return "Paid late \(Fmt.dateTime.string(from: at)) · was due \(due)"
        case let .excused(at): return "Excused by guardian \(Fmt.dateTime.string(from: at))"
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
        case .blackbaud: BlackbaudView(dismiss: dismiss, askGuardian: { present(.guardian) })
        }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ledger log").font(Theme.title(20))
            ScrollView {
                Text(model.store.recentLog().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
    }
}
