import SwiftUI
import TaxCore

struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    StampLabel(text: model.lock.isLocked ? "LOCKED" : "PAID UP", color: model.lock.isLocked ? Theme.stamp : Theme.paid)
                    if model.dryRun { StampLabel(text: "DRY RUN · NOTHING IS CLOSED", color: Theme.amber) }
                }
                Text(headline)
                    .font(Theme.title(32))
                    .foregroundStyle(Theme.ink)
                Text(subhead).foregroundStyle(Theme.inkSoft)
            }
            .padding(28)

            Rectangle().fill(Theme.rule).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.lock.overdue.isEmpty {
                        section("Overdue") {
                            ForEach(model.lock.overdue) { task in debtRow(task) }
                        }
                    }
                    if !model.lock.penalties.isEmpty {
                        section("Late fee") {
                            ForEach(model.lock.penalties) { task in penaltyRow(task) }
                        }
                    }
                    if !model.closedApps.isEmpty {
                        section(model.dryRun ? "Would have closed" : "Closed so far") {
                            Text(model.closedApps.joined(separator: ", "))
                                .font(.callout)
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    section("Still open to you") {
                        Text(Allowlist.apps.map(\.name).joined(separator: ", ")
                             + (model.settings.extraAllowedBundleIDs.isEmpty ? "" : ", plus \(model.settings.extraAllowedBundleIDs.count) your guardian added"))
                            .font(.callout)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack {
                Text("Can't get out? Only your guardian's code can override this.")
                    .font(.caption).foregroundStyle(Theme.inkSoft)
                Spacer()
                Button("Guardian…") { router.lockSheet = .guardian }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Theme.paper)
        .sheet(item: $router.lockSheet) { sheet in
            SheetContent(sheet: sheet, dismiss: { router.lockSheet = nil }, present: { router.lockSheet = $0 })
        }
    }

    private var headline: String {
        if !model.lock.isLocked { return "You're paid up." }
        if !model.lock.overdue.isEmpty { return "Payment is overdue." }
        return "Late fee in progress."
    }

    private var subhead: String {
        if !model.lock.isLocked { return "Everything is unlocked again. You can close this window." }
        if !model.lock.overdue.isEmpty {
            return "Every app outside your allowed list gets closed until you prove these are done."
        }
        if let end = model.lock.penaltyEndsAt {
            return "Proof accepted, but it was late. Unlocks in \(Fmt.span(end.timeIntervalSince(model.now))), at \(Fmt.time.string(from: end))."
        }
        return ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.inkSoft)
            content()
        }
    }

    private func debtRow(_ task: TaxTask) -> some View {
        let parts = Agenda.courseAndTitle(task)
        let latest = task.proofs.last
        let isChecking = latest.map { model.checking.contains($0.id) } ?? false
        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(parts.course.map(Theme.courseColor) ?? Theme.stamp)
                .frame(width: 4)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let course = parts.course { CourseTag(course: course) }
                    Text(parts.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !task.details.isEmpty {
                        Text(task.details)
                            .font(.callout)
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(3)
                    }
                    Text("Was due \(Fmt.dateTime.string(from: task.dueDate)) · \(Fmt.due(task, now: model.now))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.stamp)
                    if let latest, latest.verdict == .rejected {
                        Text("Last proof rejected: \(latest.reason)").font(.caption).foregroundStyle(Theme.stamp)
                    }
                }
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Pay with proof…") { router.lockSheet = .proof(task.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.stamp)
                }
            }
            .padding(14)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.rule, lineWidth: 1))
    }

    private func penaltyRow(_ task: TaxTask) -> some View {
        HStack {
            Text(Agenda.courseAndTitle(task).title)
                .font(.callout)
                .foregroundStyle(Theme.ink)
            Spacer()
            if case let .provenLate(_, end) = task.status {
                Text(Fmt.span(end.timeIntervalSince(model.now)))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(Theme.stamp)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.rule, lineWidth: 1))
    }
}
