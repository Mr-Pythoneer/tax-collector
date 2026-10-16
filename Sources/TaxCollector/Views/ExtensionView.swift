import SwiftUI
import TaxCore

/// Ask Claude for up to 12 more hours. Only with a good track record, once per task, before the deadline.
struct ExtensionView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    let dismiss: () -> Void

    @State private var hours = 6
    @State private var reason = ""
    @State private var sentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let task = model.task(taskID) {
                header(task)
                if let sentID, let request = task.extensions?.first(where: { $0.id == sentID }) {
                    result(request, task: task)
                } else if let why = model.extensionWhyNot(task) {
                    blocked(why)
                } else {
                    form(task)
                }
            } else {
                Text("This task no longer exists.")
                HStack { Spacer(); Button("Close", action: dismiss) }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func header(_ task: TaxTask) -> some View {
        let parts = Agenda.courseAndTitle(task)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Ask for More Time").font(.title2.bold())
            Text(parts.title).font(.headline)
            if parts.course != nil { CourseLabel(task) }
            Text("Due \(Fmt.dateTime.string(from: task.dueDate)) (\(Fmt.relative(task.dueDate, now: model.now)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var record: some View {
        let r = model.trackRecord
        return GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 30 days: \(r.onTime) on time, \(r.late) late, \(r.missed) missed (\(Int((r.onTimeRate * 100).rounded()))% on time).")
                Text("Extensions in the last 7 days: \(r.extensionsThisWeek) of \(ExtensionPolicy.perWeek).")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Your track record").font(.callout.weight(.semibold))
        }
    }

    private func blocked(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(why, systemImage: "hand.raised.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            record
            Text("To ask for more time you need at least \(ExtensionPolicy.minimumFinished) finished tasks in the last 30 days, at least \(Int(ExtensionPolicy.minimumOnTimeRate * 100))% of them on time, and to ask before the deadline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close", action: dismiss).keyboardShortcut(.defaultAction) }
        }
    }

    private func form(_ task: TaxTask) -> some View {
        let reasonOK = reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= ExtensionPolicy.minimumReason
        return VStack(alignment: .leading, spacing: 14) {
            record
            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: $hours, in: 1...ExtensionPolicy.maxHours) {
                    Text("Extra time: \(hours) hour\(hours == 1 ? "" : "s")")
                }
                Text("If Claude agrees, the new deadline is \(Fmt.dateTime.string(from: task.dueDate.addingTimeInterval(TimeInterval(hours) * 3600))). It might give you less.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Why do you need more time?").font(.callout)
                TextEditor(text: $reason)
                    .font(.body)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                Text("Real obstacles can work, like being sick, a family event or a broken computer. \"I didn't have time\" won't. You get one try per task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Ask Claude") {
                    model.requestExtension(taskID: taskID, hours: hours, reason: reason)
                    sentID = model.latestExtension(taskID)?.id
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!reasonOK)
            }
        }
    }

    private func result(_ request: Extension, task: TaxTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.decision {
            case nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Claude is deciding. Until it answers, the deadline won't lock anything.")
                }
            case .granted:
                Label("Granted: \(request.hoursGranted) more hour\(request.hoursGranted == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if !request.answer.isEmpty { Text(request.answer) }
                Text("New deadline: \(Fmt.dateTime.string(from: task.dueDate)).").foregroundStyle(.secondary)
            case .denied:
                Label("Not granted", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                if !request.answer.isEmpty { Text(request.answer) }
                Text("The deadline stays at \(Fmt.dateTime.string(from: task.dueDate)).").foregroundStyle(.secondary)
            case .error:
                Label("Couldn't ask Claude", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(request.answer)
                Text("This didn't use up your request. You can try again.").foregroundStyle(.secondary)
            }
            HStack {
                if request.decision == .error {
                    Button("Try Again") { sentID = nil }
                }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
    }
}
