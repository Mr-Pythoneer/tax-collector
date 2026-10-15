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
                Text(headline).font(Theme.title(30))
                Text(subhead).foregroundStyle(.secondary)
            }
            .padding(28)

            Divider()

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
                            Text(model.closedApps.joined(separator: ", ")).font(.callout)
                        }
                    }
                    section("Still open to you") {
                        Text(Allowlist.apps.map(\.name).joined(separator: ", ")
                             + (model.settings.extraAllowedBundleIDs.isEmpty ? "" : ", plus \(model.settings.extraAllowedBundleIDs.count) your guardian added"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Text("Can't get out? Only your guardian's code can override this.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Guardian…") { router.lockSheet = .guardian }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 620, minHeight: 520)
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
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func debtRow(_ task: TaxTask) -> some View {
        let latest = task.proofs.last
        let isChecking = latest.map { model.checking.contains($0.id) } ?? false
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.title3.weight(.medium))
                if !task.details.isEmpty { Text(task.details).font(.callout).foregroundStyle(.secondary) }
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
    }

    private func penaltyRow(_ task: TaxTask) -> some View {
        HStack {
            Text(task.title).font(.callout)
            Spacer()
            if case let .provenLate(_, end) = task.status {
                Text(Fmt.span(end.timeIntervalSince(model.now)))
                    .font(.system(.title3, design: .monospaced))
            }
        }
    }
}
