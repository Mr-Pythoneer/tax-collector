import SwiftUI
import TaxCore

/// First launch: explain the rules, then have someone else set the guardian code.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var code2 = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Tax Collector").font(.title2.bold())
                    Text("Deadlines you can't skip.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add a task and when it's due. Before then, submit proof that it's done: a screenshot, photo or file. Claude checks that the proof matches the task.")
                Text("If a task is overdue with no accepted proof, Tax Collector closes every app except Arc, Claude, Microsoft 365, Mail, Zoom, VooV Meeting and Activity Monitor until you submit it. Proof that's late still unlocks the Mac, after a \(model.settings.penaltyMinutes)-minute penalty.")
            }
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask a parent or friend to choose a code and type it here. It's the only way to unlock early, excuse a task or change the rules, so don't set it yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Guardian code (at least \(Guardian.minimumLength) characters)", text: $code)
                    SecureField("Type it again", text: $code2)
                        .onSubmit(save)
                    if !message.isEmpty {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Set Guardian Code", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(code.isEmpty)
                    }
                }
                .padding(6)
            } label: {
                Text("Guardian code").font(.headline)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(28)
        .frame(maxWidth: 560)
    }

    private func save() {
        guard code.count >= Guardian.minimumLength else {
            message = "Use at least \(Guardian.minimumLength) characters."
            return
        }
        guard code == code2 else {
            message = "The two codes don't match."
            return
        }
        model.setupGuardian(code: code)
    }
}
