import Foundation
import TaxCore

extension AppModel {
    /// Picks up tasks other tools left in the inbox folder. Checked every few seconds, and once at launch.
    /// Each task is an ordinary manual task: it follows every rule (edit window, lock-in, proof) from the moment it lands.
    func importInbox() {
        guard now.timeIntervalSince(lastInboxScan) >= 5 else { return }
        lastInboxScan = now
        let dir = store.inboxURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var added = 0
        for entry in Inbox.scan(dir: dir, now: now) {
            switch entry.result {
            case .success(let item):
                let id = Inbox.taskID(for: item.id)
                if task(id) == nil {
                    var details = item.details ?? ""
                    if let from = item.from, !from.isEmpty { details += (details.isEmpty ? "" : "\n\n") + "Added by \(from)." }
                    var t = TaxTask(title: item.title, details: details, dueDate: item.due, createdAt: now)
                    t.id = id
                    tasks.append(t)
                    store.log("INBOX \(item.from ?? "a tool") added \"\(t.title)\" due \(t.dueDate)")
                    added += 1
                }
            case .failure(let reason):
                store.log("INBOX refused \(entry.url.lastPathComponent): \(reason.rawValue)")
            }
            Inbox.settle(entry, in: dir)
        }
        if added > 0 {
            save()
            tick()
        }
    }
}
