import SwiftUI
import TaxCore

/// Which list the main window shows.
enum MainTab: String, CaseIterable, Identifiable {
    case assignments = "Assignments"
    case todo = "To-Do"
    var id: String { rawValue }
}

/// A plain to-do list beside your assignments: no due dates, no proof, no credits, nothing locks.
struct TodoListView: View {
    @Environment(AppModel.self) private var model
    @State private var newTitle = ""
    /// The item a sub-item is being typed under.
    @State private var addingUnder: UUID?
    @State private var subTitle = ""
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case new
        case sub
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.title3)
                    TextField("Add a to-do and press Return", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .new)
                        .onSubmit {
                            if model.addTodo(newTitle) != nil { newTitle = "" }
                            focus = .new
                        }
                }
                .padding(.vertical, 4)
            } footer: {
                if model.todos.isEmpty {
                    Text("For anything you want to remember: clean your room, call someone at 5, finish a paragraph. No due dates, no credits, nothing locks. Right-click an item to add steps under it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }

            ForEach(Todos.topLevel(model.todos)) { item in
                TodoRow(item: item, isChild: false, addSub: { startSub(under: item.id) })
                ForEach(Todos.children(of: item.id, in: model.todos)) { child in
                    TodoRow(item: child, isChild: true, addSub: { startSub(under: item.id) })
                }
                if addingUnder == item.id {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                        TextField("Add a step", text: $subTitle)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .sub)
                            .onSubmit {
                                if model.addTodo(subTitle, under: item.id) != nil {
                                    subTitle = ""
                                    focus = .sub
                                } else {
                                    addingUnder = nil
                                }
                            }
                            .onExitCommand { addingUnder = nil }
                    }
                    .padding(.leading, 28)
                }
            }

            if model.todos.contains(where: \.isDone) {
                Button("Clear Completed") { model.clearDoneTodos() }
                    .buttonStyle(.link)
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
        .navigationTitle("Tax Collector")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    focus = .new
                } label: {
                    Label("New To-Do", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("New to-do")
            }
        }
        .onChange(of: focus) { _, now in
            if now != .sub && subTitle.isEmpty { addingUnder = nil }
        }
        .onAppear { if model.todos.isEmpty { focus = .new } }
    }

    private var subtitle: String {
        let open = Todos.openCount(model.todos)
        var s = open == 0 ? "Nothing to do" : "\(open) to do"
        if model.dryRun { s = "Test mode · " + s }
        return s
    }

    private func startSub(under id: UUID) {
        subTitle = ""
        addingUnder = id
        DispatchQueue.main.async { focus = .sub }
    }
}

private struct TodoRow: View {
    @Environment(AppModel.self) private var model
    let item: TodoItem
    let isChild: Bool
    let addSub: () -> Void
    @State private var title = ""
    @State private var hovering = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.setTodoDone(item.id, !item.isDone)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(isChild ? .body : .title3)
                    .foregroundStyle(item.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark as not done" : "Mark as done")

            TextField("", text: $title)
                .textFieldStyle(.plain)
                .focused($editing)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .onSubmit(commit)
                .onChange(of: editing) { _, now in if !now { commit() } }

            Spacer(minLength: 4)
            if hovering {
                if !isChild {
                    Button(action: addSub) { Image(systemName: "arrow.turn.down.right") }
                        .buttonStyle(.borderless)
                        .help("Add a step under this")
                }
                Button { model.removeTodo(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
        .padding(.leading, isChild ? 28 : 0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { title = item.title }
        .onChange(of: item.title) { _, now in if !editing { title = now } }
        .contextMenu {
            Button(item.isDone ? "Mark as Not Done" : "Mark as Done") { model.setTodoDone(item.id, !item.isDone) }
            Button(isChild ? "Add Another Step" : "Add a Step Under This", action: addSub)
            Divider()
            Button("Delete", role: .destructive) { model.removeTodo(item.id) }
        }
    }

    private func commit() {
        let clean = Todos.clean(title)
        if clean.isEmpty { title = item.title } else if clean != item.title { model.renameTodo(item.id, to: clean) }
    }
}
