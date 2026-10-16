import SwiftUI
import TaxCore
import UniformTypeIdentifiers

struct ProofSubmitView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    let dismiss: () -> Void

    @State private var note = ""
    @State private var files: [URL] = []
    @State private var sentID: UUID?
    @State private var dropTargeted = false
    @State private var snapping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task = model.task(taskID) {
                bill(task)
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
        .frame(width: 520)
    }

    private func bill(_ task: TaxTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pay with proof").font(Theme.title(20))
            Text(task.title).font(.headline)
            if !task.details.isEmpty { Text(task.details).font(.callout).foregroundStyle(.secondary) }
            Text("\(Fmt.dateTime.string(from: task.dueDate)) · \(Fmt.due(task, now: model.now))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(task.dueDate <= model.now ? Theme.stamp : .secondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What did you do?").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Evidence: screenshots, photos, PDFs or text files. For Word or PowerPoint work, export a PDF or take a screenshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                dropZone
                HStack {
                    Button("Choose files…", action: choose)
                    Button(snapping ? "Select an area…" : "Snap screenshot", action: snap)
                        .disabled(snapping)
                }
                .controlSize(.small)
            }

            HStack {
                Text("Claude checks the evidence against the task.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Send to the auditor", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty)
            }
        }
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            if files.isEmpty {
                Text("Drop files here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            files.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.tertiary))
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
                    Text("The auditor is reviewing your proof. This usually takes under a minute.")
                }
            case .accepted, .guardianApproved:
                VStack(alignment: .leading, spacing: 6) {
                    StampLabel(text: "PAID", color: Theme.paid)
                    Text(proof.reason.isEmpty ? "Accepted." : proof.reason)
                    if case let .provenLate(_, end) = task.status, end > model.now {
                        Text("It was late, so the late fee applies: locked for another \(Fmt.span(end.timeIntervalSince(model.now))).")
                            .foregroundStyle(Theme.stamp)
                    }
                    if task.isFromBlackbaud && task.checklist != nil {
                        Divider().padding(.vertical, 4)
                        LastCheckPanel(taskID: task.id)
                    }
                }
            case .rejected:
                VStack(alignment: .leading, spacing: 6) {
                    StampLabel(text: "REJECTED", color: Theme.stamp)
                    Text(proof.reason)
                    if let items = task.checklist, !items.isEmpty {
                        Text("What the task asks for:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(items) { Text("• \($0.text)").font(.callout) }
                    }
                    Text("The task is still owed. Send better evidence.").foregroundStyle(.secondary)
                }
            case .error:
                VStack(alignment: .leading, spacing: 6) {
                    StampLabel(text: "NOT CHECKED", color: Theme.amber)
                    Text(proof.reason)
                    Text("Try again, or ask your guardian to approve it by hand.").foregroundStyle(.secondary)
                }
            }
            HStack {
                if proof.verdict == .rejected {
                    Button("Send new proof") {
                        sentID = nil
                        files = []
                    }
                }
                if proof.verdict == .error {
                    Button("Check again") { model.recheck(taskID: taskID, submissionID: proof.id) }
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
