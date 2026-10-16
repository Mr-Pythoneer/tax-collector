import SwiftUI
import TaxCore
import UniformTypeIdentifiers

/// Everything that makes Tax Collector easier on you lives behind the guardian code.
struct GuardianView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    @State private var code = ""
    @State private var unlocked = false
    @State private var message = ""

    var body: some View {
        Group {
            if unlocked {
                GuardianPanel(dismiss: dismiss)
            } else {
                gate
            }
        }
    }

    private var gate: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Guardian").font(Theme.title(20))
            Text("Hand the Mac to your guardian. Their code can unlock, excuse a task or change the rules.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Guardian code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(check)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(Theme.stamp)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Open", action: check).keyboardShortcut(.defaultAction).disabled(code.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func check() {
        switch model.checkGuardian(code) {
        case .ok:
            unlocked = true
        case .wrong:
            message = "Wrong code."
        case let .coolingDown(until):
            message = "Too many wrong codes. Try again at \(Fmt.time.string(from: until))."
        }
        code = ""
    }
}

private struct GuardianPanel: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    @State private var penalty = 30
    @State private var newCode = ""
    @State private var newCode2 = ""
    @State private var codeMessage = ""
    @State private var editingDue: [UUID: Date] = [:]
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Guardian panel").font(Theme.title(20))
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                unlockSection
                tasksSection
                rulesSection
                codeSection
                Section {
                    Button("Reset clock guard") { model.resetClockGuard() }
                        .help("Use this if the Mac's clock was wrong and Tax Collector thinks it's later than it is.")
                    Button("Uninstall Tax Collector…", role: .destructive) { confirmUninstall = true }
                } header: {
                    Text("Maintenance")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 620)
        .onAppear { penalty = model.settings.penaltyMinutes }
        .confirmationDialog("Uninstall Tax Collector?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
        } message: {
            Text("It stops running and won't start at login. Your tasks and proofs stay in Application Support.")
        }
    }

    private var unlockSection: some View {
        Section("Unlock") {
            if let until = model.lock.overrideUntil {
                HStack {
                    Text("Unlocked until \(Fmt.dateTime.string(from: until))")
                    Spacer()
                    Button("End now") { model.endUnlock() }
                }
            }
            HStack {
                Text("Unlock for")
                Button("1 hour") { model.unlock(hours: 1) }
                Button("3 hours") { model.unlock(hours: 3) }
                Button("1 day") { model.unlock(hours: 24) }
            }
            Text("An unlock pauses the lock. Debts stay owed and lock again when it ends.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tasksSection: some View {
        Section("Tasks") {
            if model.pendingTasks.isEmpty {
                Text("Nothing owed.").foregroundStyle(.secondary)
            }
            ForEach(model.pendingTasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(task.title).font(.body.weight(.medium))
                        Spacer()
                        let (t, c) = task.stamp(now: model.now, checking: false)
                        StampLabel(text: t, color: c)
                    }
                    if task.isPending {
                        HStack {
                            DatePicker("Due", selection: dueBinding(task), displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                            Button("Save deadline") {
                                var edited = task
                                edited.dueDate = editingDue[task.id] ?? task.dueDate
                                _ = model.saveEdit(edited, guardianApproved: true)
                                editingDue[task.id] = nil
                            }
                            .disabled(editingDue[task.id] == nil)
                        }
                    }
                    HStack {
                        if task.isPending {
                            Button("Approve latest proof") { model.approveLatestProof(task.id) }
                        }
                        Button("Excuse") { model.excuse(task.id) }
                        Button("Delete", role: .destructive) { _ = model.delete(task.id, guardianApproved: true) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var rulesSection: some View {
        Section("Rules") {
            if model.feedIsOn {
                HStack {
                    Text("Blackbaud import is on")
                    Spacer()
                    Button("Turn off") { _ = model.stopFeed(guardianApproved: true) }
                }
            }
            Stepper(value: $penalty, in: 0...240, step: 5) {
                Text("Late fee: \(penalty) min locked after late proof")
            }
            .onChange(of: penalty) { _, value in model.setPenalty(minutes: value) }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra allowed apps")
                if model.settings.extraAllowedBundleIDs.isEmpty {
                    Text("None. Only the built-in list stays open.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.settings.extraAllowedBundleIDs, id: \.self) { id in
                    HStack {
                        Text(id).font(.callout.monospaced())
                        Spacer()
                        Button("Remove") { model.disallowApp(bundleID: id) }.controlSize(.small)
                    }
                }
                Button("Add app…", action: addApp).controlSize(.small)
            }
        }
    }

    private var codeSection: some View {
        Section("Guardian code") {
            SecureField("New code (6+ characters)", text: $newCode)
            SecureField("Repeat new code", text: $newCode2)
            HStack {
                Button("Change code") {
                    guard newCode.count >= Guardian.minimumLength else {
                        codeMessage = "Use at least \(Guardian.minimumLength) characters."
                        return
                    }
                    guard newCode == newCode2 else {
                        codeMessage = "The two codes don't match."
                        return
                    }
                    model.changeGuardianCode(newCode)
                    newCode = ""
                    newCode2 = ""
                    codeMessage = "Code changed."
                }
                if !codeMessage.isEmpty { Text(codeMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func dueBinding(_ task: TaxTask) -> Binding<Date> {
        Binding(get: { editingDue[task.id] ?? task.dueDate }, set: { editingDue[task.id] = $0 })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { model.allowApp(bundleID: id) }
        }
    }
}
