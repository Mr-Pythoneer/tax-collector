import SwiftUI

/// Shows whether the Claude CLI can check proofs, and takes a long-lived token if you'd rather not rely on its login.
struct AuditorView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auditor").font(Theme.title(20))
            HStack {
                Text("Status:")
                Text(model.auditorStatus)
                    .foregroundStyle(model.auditorStatus == "Ready" ? Theme.paid : Theme.stamp)
                Spacer()
                Button("Check again") { model.refreshAuditorStatus() }.controlSize(.small)
            }
            Text("Proofs are checked by the Claude command-line tool at \(model.settings.claudePath). It needs to be signed in with your Claude account. Do one of these in Terminal:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("• `claude auth login`: sign in once. Works as long as you use it now and then.")
                Text("• `claude setup-token`: makes a token that lasts about a year. Paste it below.")
            }
            .font(.callout)
            SecureField(model.hasAuditorToken ? "Token saved. Paste a new one to replace it" : "Paste token", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("Saved only on this Mac, readable only by your user account.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.hasAuditorToken {
                    Button("Remove token", role: .destructive) { model.saveAuditorToken("") }
                }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save token") {
                    model.saveAuditorToken(token)
                    token = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
