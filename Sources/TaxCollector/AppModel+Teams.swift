import Foundation
import TaxCore

/// Importing Microsoft Teams Assignments. Works like the Blackbaud feed, but you sign in instead of pasting a link.
extension AppModel {
    var teamsIsOn: Bool { settings.teamsOn }
    var teamsImportedCount: Int { tasks.filter(\.isFromTeams).count }
    var canStopTeamsFreely: Bool {
        LockPolicy.canStopTeamsWithoutGuardian(onSince: settings.teamsOnSince, tasks: tasks, now: now)
    }

    /// Opens Microsoft's sign-in. Import starts once you're signed in. Makes things stricter, so no guardian.
    func turnOnTeams() {
        if teamsSignedIn {
            startTeams()
        } else {
            teamsWanted = true
            onTeamsSignIn()
        }
    }

    /// The sign-in window closed, signed in or not.
    func teamsSignInChanged(_ signedIn: Bool) {
        teamsSignedIn = signedIn
        if signedIn {
            if teamsWanted { startTeams() } else if teamsIsOn { syncTeams() }
        }
        teamsWanted = false
    }

    private func startTeams() {
        teamsWanted = false
        guard !teamsIsOn else { return syncTeams() }
        settings.teamsOn = true
        settings.teamsOnSince = now
        store.saveSettings(settings)
        store.log("TEAMS on")
        teamsError = nil
        syncTeams()
    }

    func stopTeams(guardianApproved: Bool = false) -> EditResult {
        guard teamsIsOn else { return .saved }
        if !guardianApproved && !canStopTeamsFreely { return .needsGuardian }
        settings.teamsOn = false
        settings.teamsOnSince = nil
        store.saveSettings(settings)
        teamsError = nil
        store.log("TEAMS off\(guardianApproved ? " (guardian)" : ""). Imported tasks stay.")
        return .saved
    }

    func syncTeams() {
        guard teamsIsOn, !teamsSyncing else { return }
        teamsSyncing = true
        lastTeamsAttempt = Date()
        let asOf = now
        Task {
            let outcome = await self.teamsFetcher(asOf)
            self.teamsSyncing = false
            // Import may have been turned off while this was in flight.
            guard self.teamsIsOn else { return }
            switch outcome {
            case let .success(items):
                self.teamsSignedIn = true
                self.importTeams(items)
            case let .failure(failure):
                if failure.signedOut { self.teamsSignedIn = false }
                if self.teamsError != failure.message { self.store.log("TEAMS failed: \(failure.message)") }
                self.teamsError = failure.message
            }
        }
    }

    func pollTeamsIfDue() {
        guard teamsIsOn, !teamsSyncing else { return }
        let wait = teamsError == nil ? Teams.pollInterval : Teams.retryInterval
        // abs(): a clock wound back shouldn't stop the checks.
        if let last = lastTeamsAttempt, abs(Date().timeIntervalSince(last)) < wait { return }
        syncTeams()
    }

    func importTeams(_ items: [TeamsAssignment]) {
        let result = Teams.sync(tasks: tasks, state: teams, assignments: items, now: now)
        tasks = result.tasks
        teams = result.state
        teams.lastSync = now
        teamsError = nil
        save()
        store.saveTeams(teams)
        for t in result.added { store.log("TEAMS imported \"\(t.title)\" due \(t.dueDate)") }
        for note in result.notes { store.log("TEAMS \(note)") }
        if !result.added.isEmpty { onImported(result.added) }
        tick()
    }
}
