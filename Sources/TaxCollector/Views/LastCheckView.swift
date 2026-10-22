import SwiftUI
import TaxCore

/// After proof is accepted: tick off everything the assignment asked for, then Tax Collector
/// marks it complete in Blackbaud, or turns it in on Teams, for you.
struct LastCheckPanel: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID

    var body: some View {
        if let task = model.task(taskID) {
            content(task)
        }
    }

    @ViewBuilder
    private func content(_ task: TaxTask) -> some View {
        let items = task.checklist ?? []
        let allDone = !items.isEmpty && items.allSatisfy(\.done)
        VStack(alignment: .leading, spacing: 10) {
            Text("Last check").font(.headline)
            Text(task.lastCheckDoneAt == nil
                 ? (task.isFromTeams
                    ? "Tick everything the assignment asked for. Then Tax Collector turns it in on Teams for you. That really hands it in to your teacher."
                    : "Tick everything the assignment asked for. Then Tax Collector marks it complete in Blackbaud.")
                 : "You confirmed all of this \(Fmt.dateTime.string(from: task.lastCheckDoneAt!)).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        Toggle(isOn: Binding(get: { item.done },
                                             set: { model.setChecklistItem(taskID, item: item.id, done: $0) })) {
                            Text(item.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(task.lastCheckDoneAt != nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if task.lastCheckDoneAt == nil {
                HStack {
                    Spacer()
                    Button("I've done all of this") { model.confirmLastCheck(taskID) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allDone)
                }
            } else {
                markStatus(task)
            }
        }
    }

    @ViewBuilder
    private func markStatus(_ task: TaxTask) -> some View {
        let teams = task.isFromTeams
        switch task.blackbaudMark {
        case nil:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(teams ? "Turning it in on Teams…" : "Marking it complete in Blackbaud…")
            }
        case let .done(at):
            Label(teams ? "Turned in on Teams at \(Fmt.time.string(from: at))."
                        : "Marked complete in Blackbaud at \(Fmt.time.string(from: at)).",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(teams ? "Couldn't turn it in on Teams: \(reason)" : "Couldn't mark it complete in Blackbaud: \(reason)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if teams {
                    Text("You can turn it in yourself on Teams with Open in Teams in the task's details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if teams && !model.teamsSignedIn {
                        Button("Sign In to Teams…") { model.onTeamsSignIn() }
                    } else if !teams && !model.blackbaudSignedIn {
                        Button("Sign In to Blackbaud…") { model.onBlackbaudSignIn() }
                    }
                    Button("Try Again") { model.markInSchool(taskID) }
                }
                .controlSize(.small)
            }
        }
    }
}

struct LastCheckView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task = model.task(taskID) {
                let parts = Agenda.courseAndTitle(task)
                VStack(alignment: .leading, spacing: 4) {
                    Text(parts.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if parts.course != nil { CourseLabel(task) }
                }
                LastCheckPanel(taskID: taskID)
            }
            HStack {
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
