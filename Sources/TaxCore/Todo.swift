import Foundation

/// A plain to-do: no due date, no proof, no credits, never locks anything. Just a list for you.
public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// When it was ticked off; nil while it's still to do.
    public var doneAt: Date?
    /// The item it sits under (one level deep), or nil for a top-level item.
    public var parent: UUID?

    public init(id: UUID = UUID(), title: String, createdAt: Date, doneAt: Date? = nil, parent: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.parent = parent
    }

    public var isDone: Bool { doneAt != nil }
}

/// The rules for the to-do list. Items keep the order they were added in; sub-items sit under their parent.
public enum Todos {
    public static let maxTitle = 300

    public static func clean(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitle))
    }

    /// Adds an item (under `parent` if given). Sub-items can't have sub-items: one under a sub-item goes
    /// under that sub-item's parent instead. Empty titles add nothing.
    @discardableResult
    public static func add(_ title: String, under parent: UUID? = nil, to items: inout [TodoItem], now: Date) -> TodoItem? {
        let title = clean(title)
        guard !title.isEmpty else { return nil }
        var parent = parent
        if let p = parent {
            guard let owner = items.first(where: { $0.id == p }) else { return nil }
            parent = owner.parent ?? owner.id
        }
        let item = TodoItem(title: title, createdAt: now, parent: parent)
        items.append(item)
        // Adding something to a finished item means it isn't finished any more.
        if let parent, let i = items.firstIndex(where: { $0.id == parent }) { items[i].doneAt = nil }
        return item
    }

    /// Ticks or unticks an item. Ticking a parent ticks everything under it; ticking the last open sub-item
    /// doesn't tick the parent (you might still have more to add).
    public static func setDone(_ id: UUID, _ done: Bool, in items: inout [TodoItem], now: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].doneAt = done ? (items[i].doneAt ?? now) : nil
        if done {
            for c in items.indices where items[c].parent == id && items[c].doneAt == nil { items[c].doneAt = now }
        } else if let parent = items[i].parent, let p = items.firstIndex(where: { $0.id == parent }) {
            items[p].doneAt = nil
        }
    }

    public static func rename(_ id: UUID, to title: String, in items: inout [TodoItem]) {
        let title = clean(title)
        guard !title.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
    }

    /// Removes an item and everything under it.
    public static func remove(_ id: UUID, from items: inout [TodoItem]) {
        items.removeAll { $0.id == id || $0.parent == id }
    }

    /// Removes every finished item (and anything under a finished parent).
    public static func clearDone(_ items: inout [TodoItem]) {
        let done = Set(items.filter(\.isDone).map(\.id))
        items.removeAll { $0.isDone || ($0.parent.map(done.contains) ?? false) }
    }

    public static func topLevel(_ items: [TodoItem]) -> [TodoItem] { items.filter { $0.parent == nil } }
    public static func children(of id: UUID, in items: [TodoItem]) -> [TodoItem] { items.filter { $0.parent == id } }
    public static func openCount(_ items: [TodoItem]) -> Int { items.filter { !$0.isDone }.count }
}
