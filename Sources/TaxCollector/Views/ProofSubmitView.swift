import SwiftUI
import TaxCore
import UniformTypeIdentifiers

struct ProofSubmitView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    let dismiss: () -> Void
    var askForTime: (() -> Void)?

    @State private var note = ""
    @State private var files: [URL] = []
    @State private var sentID: UUID?
    @State private var dropTargeted = false
    @State private var snapping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let task = model.task(taskID) {
                summary(task)
                if let sentID, let proof = task.proofs.first(where: { $0.id == sentID }) {
                    result(proof, task: task)
                } else {
                    form
                }
            } else {
                Text("This task no longer exists.")
                HStack { Spacer(); Button("Close", action: dismiss) }
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: submitTestProof)
    }

    /// Testing aid: `TAXCOLLECTOR_TEST_PROOF_NOTE` (in a test copy only) types that note and submits it,
    /// as if you had, so the checking screen can be looked at.
    private func submitTestProof() {
        let env = ProcessInfo.processInfo.environment
        guard !(env["TAXCOLLECTOR_DATA_DIR"] ?? "").isEmpty, let testNote = env["TAXCOLLECTOR_TEST_PROOF_NOTE"],
              !testNote.isEmpty, sentID == nil else { return }
        note = testNote
        send()
    }

    private func summary(_ task: TaxTask) -> some View {
        let parts = Agenda.courseAndTitle(task)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Submit Proof").font(.title2.bold())
            Text(parts.title).font(.headline)
            if parts.course != nil { CourseLabel(task) }
            if !task.details.isEmpty {
                Text(task.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Text("Due \(Fmt.dateTime.string(from: task.dueDate)) (\(Fmt.relative(task.dueDate, now: model.now)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(task.dueDate <= model.now ? Color.red : Color.secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Describe what you did").font(.callout)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                Text("Can't show it with a file, like a playing test? Leave the files empty and describe exactly what you did: what, when, how it went. Vague answers get rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(files.isEmpty && writtenEnough ? "Files (optional)" : "Files").font(.callout)
                dropZone
                HStack {
                    Button("Add Files…", action: choose)
                    Button(snapping ? "Drag to select an area…" : "Take Screenshot", action: snap)
                        .disabled(snapping)
                    Spacer()
                }
                Text("Screenshots, photos, PDFs or text files. For Word or PowerPoint work, export a PDF or take a screenshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let askForTime, let task = model.task(taskID), task.isPending, task.dueDate > model.now {
                Button("Need more time?", action: askForTime)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            HStack {
                Text(footnote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Submit", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty && !writtenEnough)
            }
        }
    }

    private var writtenEnough: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines).count >= Auditor.minimumWrittenProof
    }

    private var footnote: String {
        if !files.isEmpty { return "Claude compares your proof with the task." }
        if writtenEnough { return "No files: Claude judges your description on its own." }
        return "Add a file, or describe what you did in a sentence or two."
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 6) {
            if files.isEmpty {
                Text("Drop files here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            files.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { add(url) }
                }
            }
            return true
        }
    }

    private func result(_ proof: ProofSubmission, task: TaxTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch proof.verdict {
            case nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Claude is checking your proof. This usually takes under a minute.")
                }
                Text("Closing this window doesn't stop the check. To take this proof back, click Cancel Check: it won't count, and the task stays due.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .accepted, .guardianApproved:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accepted", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    if !proof.reason.isEmpty { Text(proof.reason) }
                    if case let .provenLate(_, end) = task.status, end > model.now {
                        Text("It was late, so the Mac stays locked for another \(Fmt.span(end.timeIntervalSince(model.now))).")
                            .foregroundStyle(.red)
                    }
                    if task.isFromBlackbaud && task.checklist != nil {
                        Divider().padding(.vertical, 4)
                        LastCheckPanel(taskID: task.id)
                    }
                }
            case .rejected:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not accepted", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(proof.reason)
                    if let items = task.checklist, !items.isEmpty {
                        Text("The task asks for:").foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(items) { Text("• \($0.text)") }
                    }
                    Text("The task is still due. Try again with clearer proof.").foregroundStyle(.secondary)
                }
            case .error:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't check it", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(proof.reason)
                    Text("Try again, or ask your guardian to approve it.").foregroundStyle(.secondary)
                }
            }
            HStack {
                if proof.verdict == .rejected {
                    Button("Submit New Proof") {
                        sentID = nil
                        files = []
                    }
                }
                if proof.verdict == .error {
                    Button("Try Again") { model.recheck(taskID: taskID, submissionID: proof.id) }
                }
                if proof.verdict == nil {
                    Button("Cancel Check") {
                        model.cancelCheck(taskID: taskID, submissionID: proof.id)
                        // A withdrawn proof is gone, so go back to the form with your note and files still in it.
                        if model.task(taskID)?.proofs.contains(where: { $0.id == proof.id }) != true { sentID = nil }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
    }

    private func add(_ url: URL) {
        if !files.contains(url) { files.append(url) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .plainText, .text]
        NSApp.activate()
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }

    private func snap() {
        snapping = true
        let dir = model.store.dir.appendingPathComponent("snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("screenshot-\(Int(Date().timeIntervalSince1970)).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                snapping = false
                if FileManager.default.fileExists(atPath: url.path) { add(url) }
            }
        }
    }

    private func send() {
        model.submitProof(taskID: taskID, note: note, files: files)
        sentID = model.latestProof(taskID)?.id
    }
}
