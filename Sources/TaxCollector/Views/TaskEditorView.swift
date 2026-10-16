import SwiftUI
import TaxCore

struct TaskEditorView: View {
    @Environment(AppModel.self) private var model
    let editing: UUID?
    let dismiss: () -> Void
    let askGuardian: () -> Void

    @State private var title = ""
    @State private var details = ""
    @State private var due = Date().addingTimeInterval(24 * 3600)
    @State private var blocked = false
    @State private var loaded = false

    private var original: TaxTask? { editing.flatMap { model.task($0) } }
    private var frozen: Bool { original.map { model.isFrozen($0) } ?? false }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && due > model.now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "New Task" : "Edit Task").font(.title2.bold())

            if case .blackbaud = original?.source {
                Label("Imported from Blackbaud. Your changes stay unless the teacher changes this assignment.",
                      systemImage: "graduationcap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if frozen {
                Label("Less than 24 hours to go, so this task is locked in. You can only move the deadline earlier. Your guardian can change anything else.",
                      systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Task", text: $title, prompt: Text("Finish history essay draft"))
                    .disabled(frozen)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Details (your proof is checked against these)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $details)
                        .font(.body)
                        .frame(height: 70)
                        .disabled(frozen)
                }
                DatePicker("Due", selection: $due, in: model.now..., displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Text("Quick:").font(.caption).foregroundStyle(.secondary)
                    Button("Tonight 9 PM") { due = at(hour: 21, daysAhead: 0) }
                    Button("Tomorrow 8 AM") { due = at(hour: 8, daysAhead: 1) }
                    Button("+1 Week") { due = Calendar.current.date(byAdding: .day, value: 7, to: due) ?? due }
                }
                .controlSize(.small)
            }
            .formStyle(.grouped)

            if editing == nil {
                Text(newTaskHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if blocked {
                HStack {
                    Text("That change needs your guardian.").foregroundStyle(.red)
                    Button("Ask Your Guardian…", action: askGuardian)
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Task" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private var newTaskHint: String {
        let left = due.timeIntervalSince(model.now)
        if left <= LockPolicy.freezeWindow {
            return "Due in under 24 hours, so after 5 minutes you won't be able to change or delete it without your guardian."
        }
        return "You can change or delete it until 24 hours before it's due. After that it's locked in."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let t = original {
            title = t.title
            details = t.details
            due = t.dueDate
        }
    }

    private func at(hour: Int, daysAhead: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: daysAhead, to: model.now) ?? model.now
        let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return d > model.now ? d : cal.date(byAdding: .day, value: 1, to: d) ?? d
    }

    private func save() {
        if var t = original {
            t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            t.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
            t.dueDate = due
            if model.saveEdit(t) == .needsGuardian {
                blocked = true
                return
            }
        } else {
            model.addTask(title: title, details: details, due: due)
        }
        dismiss()
    }
}
