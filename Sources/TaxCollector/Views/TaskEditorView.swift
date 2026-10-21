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
    @State private var repeats = false
    @State private var unit = RepeatUnit.weeks
    @State private var interval = 1
    @State private var weekdays: Set<Int> = []
    @State private var time = Date()
    @State private var start = Date()

    private var original: TaxTask? { editing.flatMap { model.task($0) } }
    private var frozen: Bool { original.map { model.isFrozen($0) } ?? false }
    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return repeats ? firstDue != nil : due > model.now
    }

    private var minuteOfDay: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The repeat as it's set up in the form.
    private var series: RecurringTask {
        RecurringTask(title: title, unit: unit, interval: interval, weekdays: weekdays, minuteOfDay: minuteOfDay,
                      startDate: start, createdAt: model.now)
    }

    /// When the first copy of a repeating task would be due.
    private var firstDue: Date? { series.nextDue(after: model.now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "New Task" : "Edit Task").font(.title2.bold())

            if let original, original.isImported {
                Label("Imported from \(original.isFromTeams ? "Teams" : "Blackbaud"). Your changes stay unless the teacher changes this assignment.",
                      systemImage: original.isFromTeams ? "person.3" : "graduationcap")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if original?.seriesID != nil {
                Label("This is one week's copy of a repeating task. Changes apply to this copy only.", systemImage: "repeat")
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
                if editing == nil {
                    Toggle("Repeats", isOn: $repeats)
                        .onChange(of: repeats) { _, on in
                            // Start from the day and time already picked.
                            if on && weekdays.isEmpty {
                                weekdays = [Calendar.current.component(.weekday, from: due)]
                                time = Self.quarterHour(due)
                                start = due
                            }
                        }
                }
                if repeats {
                    LabeledContent("Every") {
                        HStack(spacing: 6) {
                            TextField("", value: $interval, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 48)
                            Stepper("", value: $interval, in: 1...(unit == .days ? RecurringTask.maxDays : RecurringTask.maxWeeks))
                                .labelsHidden()
                            Picker("", selection: $unit) {
                                Text(interval == 1 ? "day" : "days").tag(RepeatUnit.days)
                                Text(interval == 1 ? "week" : "weeks").tag(RepeatUnit.weeks)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    if unit == .weeks {
                        LabeledContent("On") { WeekdayPicker(selection: $weekdays) }
                    }
                    DatePicker("Due at", selection: $time, displayedComponents: .hourAndMinute)
                    DatePicker("Starting", selection: $start, in: Calendar.current.startOfDay(for: model.now)...,
                               displayedComponents: .date)
                } else {
                    DatePicker("Due", selection: $due, in: model.now..., displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Text("Quick:").font(.caption).foregroundStyle(.secondary)
                        Button("Tonight 9 PM") { due = at(hour: 21, daysAhead: 0) }
                        Button("Tomorrow 8 AM") { due = at(hour: 8, daysAhead: 1) }
                        Button("+1 Week") { due = Calendar.current.date(byAdding: .day, value: 7, to: due) ?? due }
                    }
                    .controlSize(.small)
                }
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
        .onAppear(perform: presetTestRepeat)
    }

    /// Testing aid, in a test copy only: `TAXCOLLECTOR_TEST_REPEAT=days:4` or `weeks:2` opens New Task with
    /// that repeat already set, so the form can be looked at.
    private func presetTestRepeat() {
        let env = ProcessInfo.processInfo.environment
        guard editing == nil, !(env["TAXCOLLECTOR_DATA_DIR"] ?? "").isEmpty,
              let spec = env["TAXCOLLECTOR_TEST_REPEAT"]?.split(separator: ":"), spec.count == 2,
              let n = Int(spec[1]) else { return }
        title = "Math homework"
        repeats = true
        unit = spec[0] == "days" ? .days : .weeks
        interval = n
        weekdays = [Calendar.current.component(.weekday, from: due)]
        time = Self.quarterHour(due)
        start = due
    }

    /// 7:42 becomes 7:45, so a repeat starts from a round time.
    static func quarterHour(_ date: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let total = (parts.hour ?? 0) * 60 + Int((Double(parts.minute ?? 0) / 15).rounded()) * 15
        // Only the time of day is used, so 11:53 PM rounding to midnight can stay on the same date.
        return calendar.date(bySettingHour: total / 60 % 24, minute: total % 60, second: 0, of: date) ?? date
    }

    private var newTaskHint: String {
        if repeats {
            guard let firstDue else { return "Pick at least one day." }
            return "\(series.schedule()). First one: \(Fmt.dateTime.string(from: firstDue)). The next copy appears once each deadline has passed, even if you finished early, and each copy needs its own proof. Like any task, a copy locks in 24 hours before it's due."
        }
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
        } else if repeats {
            model.addRecurring(title: title, details: details, unit: unit, interval: interval, weekdays: weekdays,
                               minuteOfDay: minuteOfDay, startDate: start)
        } else {
            model.addTask(title: title, details: details, due: due)
        }
        dismiss()
    }
}

/// One button per day (S M T W T F S, like Calendar's custom repeat), in the order this Mac's week starts.
/// Any number can be on; hovering shows the full name.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                let day = (calendar.firstWeekday - 1 + i) % 7 + 1
                Toggle(isOn: Binding(
                    get: { selection.contains(day) },
                    set: { on in if on { selection.insert(day) } else { selection.remove(day) } })) {
                    Text(calendar.veryShortWeekdaySymbols[day - 1]).frame(width: 14)
                }
                .toggleStyle(.button)
                .help(calendar.weekdaySymbols[day - 1])
                .accessibilityLabel(calendar.weekdaySymbols[day - 1])
            }
        }
    }
}
