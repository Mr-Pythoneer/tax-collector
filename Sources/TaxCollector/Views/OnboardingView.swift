import SwiftUI
import TaxCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var code2 = ""
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tax Collector").font(Theme.title(30))
            VStack(alignment: .leading, spacing: 10) {
                rule("1", "You add a task and a due date.")
                rule("2", "By the deadline, you pay with proof: a screenshot, photo or file. Claude checks that it really shows the task done.")
                rule("3", "No accepted proof by then, and every app except Arc, Claude, Microsoft 365, Mail, Zoom, VooV Meeting and Activity Monitor gets closed until you pay.")
                rule("4", "Paying late still costs a late fee: \(model.settings.penaltyMinutes) more minutes locked.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Hand the Mac to your guardian").font(.headline)
                Text("A parent or friend sets a code only they know. It's the only way to unlock early, excuse a task or change the rules. Don't set it yourself, or the whole thing is pointless.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Guardian code (\(Guardian.minimumLength)+ characters)", text: $code)
                    .textFieldStyle(.roundedBorder)
                SecureField("Repeat code", text: $code2)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.stamp) }
                HStack {
                    Spacer()
                    Button("Set guardian code", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.isEmpty)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
    }

    private func rule(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n).font(.system(.callout, design: .monospaced).weight(.bold)).foregroundStyle(Theme.stamp)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
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
