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
                ledger
            }
        }
        .frame(minWidth: 600, minHeight: 560)
        .background(Theme.paper)
        .sheet(item: $router.mainSheet) { sheet in
            SheetContent(sheet: sheet, dismiss: { router.mainSheet = nil },
                         present: { router.mainSheet = $0 })
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            if model.lock.isLocked {
                lockedBar
            } else if let until = model.lock.overrideUntil {
                infoBar("Guardian unlock until \(Fmt.time.string(from: until)). The debts are still owed.",
                        color: Theme.amber)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            if model.tasks.isEmpty {
                empty
            } else {
                AgendaList()
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tax Collector")
                    .font(Theme.title(30))
                    .foregroundStyle(Theme.ink)
                summary
            }
            Spacer()
            if model.dryRun { StampLabel(text: "DRY RUN", color: Theme.amber) }
            Button {
                router.mainSheet = .newTask
            } label: {
                Label("New task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ink)
            .keyboardShortcut("n")
        }
    }

    /// "1 overdue · 3 due today · 11 owed", with the counts that matter in colour.
    private var summary: some View {
        let owed = model.tasks.filter(\.isPending)
        let overdue = owed.filter { $0.dueDate <= model.now }.count
        let cal = Calendar.current
        let today = owed.filter { $0.dueDate > model.now && cal.isDate($0.dueDate, inSameDayAs: model.now) }.count
        return HStack(spacing: 6) {
            if owed.isEmpty {
                Text("Nothing owed. Add a task to put yourself on the hook.")
                    .foregroundStyle(Theme.inkSoft)
            } else {
                if overdue > 0 {
                    Text("\(overdue) overdue").foregroundStyle(Theme.stamp).fontWeight(.semibold)
                    Text("·").foregroundStyle(Theme.inkSoft)
                }
                if today > 0 {
                    Text("\(today) due today").foregroundStyle(Theme.amber).fontWeight(.semibold)
                    Text("·").foregroundStyle(Theme.inkSoft)
                }
                Text("\(owed.count) owed").foregroundStyle(Theme.inkSoft)
            }
        }
        .font(.system(size: 13))
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
        .background(Theme.stampFill)
    }

    private func infoBar(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(color.opacity(0.18))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()
            Text("The ledger is empty.")
                .font(Theme.title(22))
                .foregroundStyle(Theme.ink)
            Text("Add a task and a due date, or turn on Blackbaud import. If you can't prove it's done by then, every app except your allowed ones gets closed until you pay up.")
                .foregroundStyle(Theme.inkSoft)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("New task…") { router.mainSheet = .newTask }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ink)
                Button("Import from Blackbaud…") { router.mainSheet = .blackbaud }
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Blackbaud") { router.mainSheet = .blackbaud }
                .foregroundStyle(model.feedError == nil ? Theme.ink : Theme.stamp)
                .help(model.feedError ?? (model.feedIsOn ? "Importing assignments from Blackbaud" : "Import assignments from Blackbaud"))
            Button("Auditor: \(model.auditorStatus)") { router.mainSheet = .auditor }
                .foregroundStyle(model.auditorStatus == "Ready" ? Theme.paid : Theme.stamp)
            Button("Log") { router.mainSheet = .log }
            Spacer()
            Menu {
                Picker("Appearance", selection: Binding(get: { model.settings.appearance },
                                                        set: { model.setAppearance($0) })) {
                    Text("Paper").tag("paper")
                    Text("Ink").tag("ink")
                    Text("Match Mac").tag("system")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Appearance")
            Button("Guardian…") { router.mainSheet = .guardian }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.ink)
    }
}

/// Owed tasks as a planner: late fee, overdue, then one block per day, soonest first and numbered in that order.
/// Paid Blackbaud work waiting for its last check comes next, and everything settled folds away at the bottom.
struct AgendaList: View {
    @Environment(AppModel.self) private var model
    @State private var showSettled = false

    var body: some View {
        let sections = Agenda.sections(model.tasks, now: model.now)
        let firstUpcoming = sections.first { if case .day = $0.kind { true } else { false } }?.tasks.first?.id
        let finishUp = model.tasks.filter { task in
            if task.needsLastCheck { return true }
            if case .failed = task.blackbaudMark { return true }
            return false
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    AgendaSectionView(section: section,
                                      firstRank: sections.prefix(index).reduce(0) { $0 + $1.tasks.count } + 1,
                                      nextUp: firstUpcoming)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                if sections.isEmpty {
                    Text("Nothing owed right now.")
                        .font(Theme.title(17))
                        .foregroundStyle(Theme.inkSoft)
                        .padding(.vertical, 22)
                }
                if !finishUp.isEmpty {
                    finishUpSection(finishUp)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                settled
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func finishUpSection(_ tasks: [TaxTask]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SectionMark(top: "PAID", middle: "✓", bottom: "finish up", color: Theme.paid)
            VStack(spacing: 8) {
                ForEach(tasks) { TaskRow(task: $0, rank: nil, isNext: false) }
            }
        }
        .padding(.vertical, 14)
    }

    private var settled: some View {
        let done = model.settledTasks.filter { task in
            !task.needsLastCheck && { if case .failed = task.blackbaudMark { return false }; return true }()
        }
        return VStack(alignment: .leading, spacing: 8) {
            if !done.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showSettled.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showSettled ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("Settled").font(.system(size: 13, weight: .semibold))
                        Text("\(done.count)").font(.system(size: 12).monospacedDigit())
                    }
                    .foregroundStyle(Theme.inkSoft)
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                if showSettled {
                    ForEach(done.prefix(40)) { SettledRow(task: $0) }
                }
            }
        }
    }
}

/// The left-hand date column of a planner block.
struct SectionMark: View {
    let top: String
    let middle: String
    let bottom: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(top)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1)
            Text(middle)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .monospacedDigit()
            Text(bottom)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .frame(width: 66)
        .padding(.top, 2)
    }
}

struct AgendaSectionView: View {
    @Environment(AppModel.self) private var model
    let section: AgendaSection
    let firstRank: Int
    let nextUp: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            mark
            VStack(spacing: 8) {
                ForEach(Array(section.tasks.enumerated()), id: \.element.id) { offset, task in
                    TaskRow(task: task, rank: firstRank + offset, isNext: task.id == nextUp)
                }
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var mark: some View {
        switch section.kind {
        case .lateFee:
            SectionMark(top: "LATE", middle: "$", bottom: "fee running", color: Theme.stamp)
        case .overdue:
            SectionMark(top: "PAST", middle: "!", bottom: "overdue", color: Theme.stamp)
        case let .day(day):
            let cal = Calendar.current
            let relative = cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow"
                : Fmt.formatted(day, "MMM")
            SectionMark(top: Fmt.formatted(day, "EEE").uppercased(),
                        middle: Fmt.formatted(day, "d"),
                        bottom: relative,
                        color: cal.isDateInToday(day) ? Theme.amber : Theme.ink)
        }
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask
    /// Place in the due-date ranking, or nil outside it.
    let rank: Int?
    let isNext: Bool

    var body: some View {
        let parts = Agenda.courseAndTitle(task)
        let latest = task.proofs.last
        let isChecking = latest.map { model.checking.contains($0.id) } ?? false
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(parts.course.map(Theme.courseColor) ?? Theme.rule)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                topLine(course: parts.course)
                Text(parts.title)
                    .font(.system(size: isNext ? 17 : 14.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.details.isEmpty {
                    Text(task.details)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(isNext ? 3 : 2)
                }
                if let latest, task.isPending, latest.verdict == .rejected || latest.verdict == .error {
                    Text("Last proof \(latest.verdict == .rejected ? "rejected" : "not checked"): \(latest.reason)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.stamp)
                        .lineLimit(2)
                }
                bottomLine(isChecking: isChecking)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isNext ? 12 : 10)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isNext ? Theme.amber.opacity(0.7) : Theme.rule,
                                                          lineWidth: isNext ? 1.5 : 1))
        .contextMenu {
            if task.isPending { Button("Edit…") { router.mainSheet = .edit(task.id) } }
            Button("Delete", role: .destructive) {
                if model.delete(task.id) == .needsGuardian { router.mainSheet = .guardian }
            }
        }
    }

    private func topLine(course: String?) -> some View {
        HStack(spacing: 8) {
            if let rank {
                Text(String(format: "%02d", rank))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.inkSoft)
            }
            if isNext {
                Text("NEXT UP")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.amber)
            }
            if let course { CourseTag(course: course) }
            if model.isFrozen(task) && task.isPending {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.inkSoft)
                    .help("Locked in: less than 24 hours to go. Only your guardian can change it.")
            }
            Spacer(minLength: 8)
            Text(Fmt.time.string(from: task.dueDate))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(task.isPending ? task.urgencyColor(now: model.now) : Theme.inkSoft)
        }
    }

    @ViewBuilder
    private func bottomLine(isChecking: Bool) -> some View {
        HStack(spacing: 10) {
            if task.isPending {
                Text(Fmt.due(task, now: model.now))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(task.urgencyColor(now: model.now))
            } else if case let .provenLate(_, end) = task.status, end > model.now {
                Text("late fee ends in \(Fmt.span(end.timeIntervalSince(model.now)))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.stamp)
            } else {
                let (text, color) = task.stamp(now: model.now, checking: false)
                StampLabel(text: text, color: color)
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
                Text("Checking proof…").font(.system(size: 12)).foregroundStyle(Theme.amber)
            } else if task.isPending {
                Button("Pay with proof…") { router.mainSheet = .proof(task.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(task.dueDate <= model.now ? Theme.stamp : Theme.ink)
            } else if task.needsLastCheck {
                Button("Last check…") { router.mainSheet = .lastCheck(task.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.paid)
            } else if case .failed = task.blackbaudMark {
                Button("Retry Blackbaud…") { router.mainSheet = .lastCheck(task.id) }
                    .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }
}

/// A finished task, kept small so the owed work stays the focus.
struct SettledRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: TaxTask

    var body: some View {
        let parts = Agenda.courseAndTitle(task)
        let (stampText, stampColor) = task.stamp(now: model.now, checking: false)
        HStack(spacing: 10) {
            Circle()
                .fill(parts.course.map(Theme.courseColor) ?? Theme.rule)
                .frame(width: 6, height: 6)
            Text(parts.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
            Spacer()
            if case .done = task.blackbaudMark {
                Text("Completed in Blackbaud").font(.system(size: 11)).foregroundStyle(Theme.paid)
            }
            Text(Fmt.formatted(task.dueDate, "MMMd"))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
            StampLabel(text: stampText, color: stampColor)
        }
        .padding(.vertical, 3)
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
        content.background(Theme.paper)
    }

    @ViewBuilder
    private var content: some View {
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
