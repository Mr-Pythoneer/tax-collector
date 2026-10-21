import SwiftUI
import TaxCore

/// Imports Microsoft Teams Assignments. Turning it on never needs the guardian; turning it off can.
struct TeamsView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    let askGuardian: () -> Void

    @State private var blocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Microsoft Teams").font(.title2.bold())
            if model.teamsIsOn { connected } else { setup }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: Not on

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import your assignments from Teams as tasks. Tax Collector checks Teams every 30 minutes and adds anything new that's due later and not handed in yet.")
                .fixedSize(horizontal: false, vertical: true)
            Text("You sign in with your school account on Microsoft's own page; Tax Collector never sees your password. Tick \"Stay signed in\" so you don't have to sign in again. Tax Collector only reads your assignments: it never hands anything in or changes anything in Teams.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Turning import on doesn't need your guardian. Turning it off does while anything it imported is due within 24 hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.teamsWanted {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to sign in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.teamsWanted ? "Show Sign-In Window" : "Sign In and Turn On Import") { model.turnOnTeams() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: On

    private var connected: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.3")
                Text("Importing from Microsoft Teams")
            }
            .font(.body.weight(.medium))
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(model.teamsError == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sync Now") { model.syncTeams() }
                    .disabled(model.teamsSyncing)
                if model.teamsSyncing { ProgressView().controlSize(.small) }
                if !model.teamsSignedIn && !model.teamsSyncing && model.teamsError != nil {
                    Button("Sign In Again…") { model.onTeamsSignIn() }
                }
                Spacer()
                Button("Turn Off Import") {
                    blocked = model.stopTeams() == .needsGuardian
                }
            }
            if blocked {
                HStack {
                    Text("Something it imported is locked in, so turning it off needs your guardian.")
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ask Your Guardian…", action: askGuardian)
                }
                .font(.callout)
            }
            Divider()
            Text("Handing work in on Teams doesn't finish the task here: you still submit proof to Tax Collector. Deleting an imported task follows the usual rule, and it won't be imported again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.teamsSignedIn {
                HStack {
                    Spacer()
                    Button("Sign Out of Teams") { model.onTeamsSignOut() }
                        .font(.callout)
                }
            }
        }
    }

    private var statusLine: String {
        if let error = model.teamsError { return error }
        let count = model.teamsImportedCount
        guard let last = model.teams.lastSync else {
            return model.teamsSyncing ? "Checking Teams…" : "Not synced yet."
        }
        return "Last synced \(Fmt.dateTime.string(from: last)) · \(count) imported task\(count == 1 ? "" : "s")"
    }
}
