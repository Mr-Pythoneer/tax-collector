import Foundation
import TaxCore

/// The to-do list. Nothing here touches deadlines, locks or credits.
extension AppModel {
    @discardableResult
    func addTodo(_ title: String, under parent: UUID? = nil) -> TodoItem? {
        let item = Todos.add(title, under: parent, to: &todos, now: now)
        if item != nil { store.saveTodos(todos) }
        return item
    }

    func setTodoDone(_ id: UUID, _ done: Bool) {
        Todos.setDone(id, done, in: &todos, now: now)
        store.saveTodos(todos)
    }

    func renameTodo(_ id: UUID, to title: String) {
        Todos.rename(id, to: title, in: &todos)
        store.saveTodos(todos)
    }

    func removeTodo(_ id: UUID) {
        Todos.remove(id, from: &todos)
        store.saveTodos(todos)
    }

    func clearDoneTodos() {
        Todos.clearDone(&todos)
        store.saveTodos(todos)
    }
}
