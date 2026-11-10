import SwiftUI
import TaxCore

/// Shown over a watched site or app. Nothing is closed: you use your time, buy some, ask for a school pass, or leave.
/// It fills the panel, which follows the window underneath, and covers it so the page can't be used.
struct CheckpointView: View {
    @Environment(AppModel.self) private var model
    let item: WatchItem
    let onLeave: () -> Void

    private enum Mode { case choose, buy, school }

    /// A site: the browser goes back a page, and its tabs stay clickable around the checkpoint.
    /// An app: it's hidden (not closed).
    private var leaveLabel: String { item.isSite ? "Go Back" : "Not Now" }

    @State private var mode: Mode = .choose
    @State private var minutes = 30
    @State private var taskID: UUID?
    @State private var reason = ""
    @State private var message: String?
    /// The pass you just asked for, so its answer stays up after Claude decides.
    @State private var sentID: UUID?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                card
                    .frame(maxWidth: 480)
                    .padding(geo.size.width < 520 ? 14 : 28)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.automatic)
        }
        .background {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Color.black.opacity(0.25)
            }
            .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onAppear {
            if taskID == nil { taskID = model.tasksForPasses.first?.id }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            status
            if let pass = shownPass {
                passState(pass)
            } else {
                switch mode {
                case .choose: choices
                case .buy: buyForm
                case .school: schoolForm
                }
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            WatchIcon(item: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Checkpoint").font(.title2.bold())
                Text("\(item.name) is on your watchlist.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: some View {
        HStack(spacing: 18) {
            LabeledValue(label: "Balance", value: Credits.format(model.balance))
            LabeledValue(label: "Time left", value: Credits.duration(model.freeTimeLeft))
        }
    }

    // MARK: Choosing

    private var choices: some View {
        let locked = model.lock.isLocked
        return VStack(alignment: .leading, spacing: 10) {
            if locked {
                Label("Free time is off during a lock. Pay off what's overdue first. You can still ask for a school pass.",
                      systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if model.freeTimeLeft > 0 {
                    Button {
                        message = model.signIn()
                    } label: {
                        Text("Use My Time Left (\(Credits.duration(model.freeTimeLeft)))").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button {
                    message = nil
                    mode = .buy
                } label: {
                    Text("Buy Time…").frame(maxWidth: .infinity)
                }
            }
            Button {
                message = nil
                mode = .school
            } label: {
                Text("I Need It for School…").frame(maxWidth: .infinity)
            }
            Button(role: .cancel, action: onLeave) {
                Text(leaveLabel).frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
    }

    // MARK: Buying time

    private var buyForm: some View {
        let cost = Double(minutes) / 30
        let short = model.balance + 0.0001 < cost
        return VStack(alignment: .leading, spacing: 12) {
            Text("Buy time").font(.headline)
            Picker("How long", selection: $minutes) {
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("1 h").tag(60)
                Text("1 h 30").tag(90)
                Text("2 h").tag(120)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Stepper(value: $minutes, in: 15...120, step: 15) {
                Text("\(Credits.duration(TimeInterval(minutes) * 60)) costs \(Credits.format(cost))")
                    .monospacedDigit()
            }
            Text(short
                 ? "You have \(Credits.format(model.balance)). You need \(Credits.format(cost - model.balance)) more."
                 : "It counts down only while something on your watchlist is in front. You can sign out to save the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") {
                    message = nil
                    mode = .choose
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Buy and Sign In") {
                    message = model.buyTimeAndSignIn(credits: cost)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(short || model.lock.isLocked)
            }
        }
    }

    // MARK: School pass

    private var schoolForm: some View {
        let tasks = model.tasksForPasses
        let reasonOK = reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
        return VStack(alignment: .leading, spacing: 12) {
            Text("I need it for school").font(.headline)
            if tasks.isEmpty {
                Text("You have nothing due, so there's no task to ask a pass for.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back") { mode = .choose }.keyboardShortcut(.cancelAction)
                    Spacer()
                }
            } else {
                Picker("For", selection: $taskID) {
                    ForEach(tasks) { task in
                        Text(Agenda.courseAndTitle(task).title).tag(Optional(task.id))
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("What do you need \(item.name) for?").font(.callout)
                    TextEditor(text: $reason)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                    Text("Be specific, like the video your teacher set. Claude decides, and can give up to \(Rewards.maxPassMinutes) minutes for \(item.isSite ? "this site" : "this app") only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Back") {
                        message = nil
                        mode = .choose
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Ask Claude", action: ask)
                        .buttonStyle(.borderedProminent)
                        .disabled(taskID == nil || !reasonOK)
                }
            }
        }
        .onAppear {
            if taskID == nil || !tasks.contains(where: { $0.id == taskID }) { taskID = tasks.first?.id }
        }
    }

    private func ask() {
        guard let taskID else { return }
        if let why = model.askPass(itemID: item.id, taskID: taskID, reason: reason) {
            message = why
            return
        }
        message = nil
        sentID = model.latestPass(itemID: item.id)?.id
    }

    /// A pass still being decided, or the answer to the one you just asked for.
    private var shownPass: ResearchPass? {
        guard let pass = model.latestPass(itemID: item.id) else { return nil }
        if pass.decision == nil || pass.id == sentID { return pass }
        return nil
    }

    private func passState(_ pass: ResearchPass) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For \(pass.taskTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch pass.decision {
            case nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Claude is deciding…")
                }
            case .granted:
                Label("Granted: \(pass.minutes) min", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if !pass.answer.isEmpty { Text(pass.answer).fixedSize(horizontal: false, vertical: true) }
            case .denied:
                Label("Not granted", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                if !pass.answer.isEmpty { Text(pass.answer).fixedSize(horizontal: false, vertical: true) }
            case .error:
                Label("Couldn't ask Claude", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(pass.answer).fixedSize(horizontal: false, vertical: true)
                Text("This didn't use up a pass. You can ask again.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if pass.decision == .error {
                    Button("Ask Again") {
                        sentID = nil
                        mode = .school
                    }
                } else if pass.decision == .denied {
                    Button("Back") {
                        sentID = nil
                        reason = ""
                        mode = .choose
                    }
                }
                Spacer()
                Button(leaveLabel, action: onLeave)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(.callout)
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}
