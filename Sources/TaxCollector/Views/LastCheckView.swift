import SwiftUI
import TaxCore

/// After proof is accepted: tick off everything the assignment asked for, then Tax Collector
/// marks it Completed in Blackbaud for you.
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
                 ? "Tick off everything the assignment asked for. Then Tax Collector marks it Completed in Blackbaud."
                 : "You confirmed all of this \(Fmt.dateTime.string(from: task.lastCheckDoneAt!)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { item.done },
                                         set: { model.setChecklistItem(taskID, item: item.id, done: $0) })) {
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(task.lastCheckDoneAt != nil)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

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
        switch task.blackbaudMark {
        case nil:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Marking it Completed in Blackbaud…")
            }
            .font(.callout)
        case let .done(at):
            HStack(spacing: 8) {
                StampLabel(text: "DONE IN BLACKBAUD", color: Theme.paid)
                Text("Marked Completed \(Fmt.time.string(from: at)).").font(.callout)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't mark it in Blackbaud: \(reason)")
                    .font(.callout)
                    .foregroundStyle(Theme.stamp)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if !model.blackbaudSignedIn {
                        Button("Sign in to Blackbaud…") { model.onBlackbaudSignIn() }
                    }
                    Button("Try again") { model.markInBlackbaud(taskID) }
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
                    if let course = parts.course { CourseTag(course: course) }
                    Text(parts.title)
                        .font(Theme.title(20))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
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
