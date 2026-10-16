import AppKit
import SwiftUI
import TaxCore

/// Everything about one assignment: what to do, the teacher's files and links, and your proof so far.
/// A window of its own, so it can stay open next to Word while you work.
struct AssignmentDetailView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    @State private var sheet: Sheet?
    /// The teacher's instructions, converted once per page.
    @State private var instructionsText: AttributedString?
    @State private var detailsText: AttributedString?

    var body: some View {
        Group {
            if let task = model.task(taskID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(task)
                        actions(task)
                        instructions(task)
                        if case let .loaded(page) = model.details[taskID] {
                            files(page)
                            links(page)
                        }
                        blackbaudStatus(task)
                        checklist(task)
                        proofHistory(task)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("This task was deleted", systemImage: "trash")
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        // Links in the teacher's text open the same lock-safe way as everything else here.
        .environment(\.openURL, OpenURLAction { url in
            model.open(url)
            return .handled
        })
        .task { model.loadDetails(taskID) }
        .task(id: instructionsHTML) {
            instructionsText = instructionsHTML.isEmpty ? nil : RichText.fromHTML(instructionsHTML)
        }
        .task(id: model.task(taskID)?.details ?? "") {
            detailsText = (model.task(taskID)?.details).map(RichText.linkified)
        }
        .sheet(item: $sheet) { s in
            SheetContent(sheet: s, dismiss: { sheet = nil }, present: { sheet = $0 })
        }
    }

    // MARK: Parts

    private func header(_ task: TaxTask) -> some View {
        let parts = Agenda.courseAndTitle(task)
        let (word, color) = task.statusWord(now: model.now, checking: false)
        return VStack(alignment: .leading, spacing: 5) {
            Text(parts.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            if parts.course != nil { CourseLabel(task) }
            HStack(spacing: 6) {
                Text("Due \(Fmt.dateTime.string(from: task.dueDate))")
                if task.isPending {
                    Text("(\(Fmt.relative(task.dueDate, now: model.now)))")
                        .foregroundStyle(task.urgencyColor(now: model.now))
                }
                Text("·")
                Text(word).foregroundStyle(color)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            if case let .loaded(page) = model.details[taskID], !page.type.isEmpty || page.maxPoints != nil {
                Text([page.type.isEmpty ? nil : page.type,
                      page.maxPoints.map(pointsText),
                      page.submitsOnline ? "handed in on Blackbaud" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ task: TaxTask) -> some View {
        HStack(spacing: 10) {
            if task.isPending {
                Button("Submit Proof…") { sheet = .proof(taskID) }
                    .buttonStyle(.borderedProminent)
                if task.dueDate > model.now {
                    Button("Ask for More Time…") { sheet = .extend(taskID) }
                }
            } else if task.needsLastCheck {
                Button("Last Check…") { sheet = .lastCheck(taskID) }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            if let url = blackbaudPage(task) {
                Button {
                    model.open(url)
                } label: {
                    Label("Open in Blackbaud", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    private func instructions(_ task: TaxTask) -> some View {
        section("What to do") {
            if let instructionsText {
                Text(instructionsText).textSelection(.enabled)
            } else if !task.details.isEmpty {
                Text(detailsText ?? AttributedString(task.details)).textSelection(.enabled)
            } else {
                Text("No instructions.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func files(_ page: AssignmentDetails) -> some View {
        if !page.attachments.isEmpty {
            section("Teacher's files") {
                ForEach(page.attachments) { file in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (file.fileName as NSString).pathExtension) ?? .data))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.title)
                            if file.title != file.fileName {
                                Text(file.fileName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.downloading.contains(file.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Open") { model.openAttachment(file, taskID: taskID) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func links(_ page: AssignmentDetails) -> some View {
        if !page.links.isEmpty {
            section("Links") {
                ForEach(page.links) { link in
                    Button { model.open(link.url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                            Text(link.title)
                            let site = (link.url.host ?? "").replacingOccurrences(of: "www.", with: "")
                            if !site.isEmpty, link.title != link.url.host, link.title != site {
                                Text(site).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// Where the page from Blackbaud stands, and what to do if it can't load.
    @ViewBuilder
    private func blackbaudStatus(_ task: TaxTask) -> some View {
        if task.isFromBlackbaud {
            switch model.details[taskID] {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the teacher's files from Blackbaud…").foregroundStyle(.secondary)
                }
                .font(.callout)
            case let .failed(message, signedOut):
                VStack(alignment: .leading, spacing: 6) {
                    if signedOut {
                        Label("Sign in to Blackbaud to see the teacher's files and the full instructions.",
                              systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("Couldn't load the teacher's files.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if signedOut {
                            Button("Sign In to Blackbaud…") { model.onBlackbaudSignIn() }
                        }
                        Button("Try Again") { model.loadDetails(taskID, force: true) }
                    }
                    .controlSize(.small)
                }
                .font(.callout)
            case .loaded(let page) where page.attachments.isEmpty && page.links.isEmpty:
                Text("No files or links attached.").font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func checklist(_ task: TaxTask) -> some View {
        if let items = task.checklist, !items.isEmpty {
            section("What it asks for") {
                ForEach(items) { item in
                    Label(item.text, systemImage: item.done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.done ? Color.secondary : Color.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func proofHistory(_ task: TaxTask) -> some View {
        if !task.proofs.isEmpty {
            section("Your proof") {
                ForEach(task.proofs.reversed()) { proof in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            verdictLabel(proof)
                            Text(Fmt.dateTime.string(from: proof.submittedAt)).foregroundStyle(.secondary)
                            Text(proof.attachments.isEmpty ? "written" : "\(proof.attachments.count) file\(proof.attachments.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            if proof.verdict == nil {
                                Spacer()
                                Button("Cancel Check") { model.cancelCheck(taskID: taskID, submissionID: proof.id) }
                                    .controlSize(.small)
                            }
                        }
                        .font(.callout)
                        if !proof.reason.isEmpty {
                            Text(proof.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if !proof.note.isEmpty {
                            Text("You wrote: \(proof.note)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func verdictLabel(_ proof: ProofSubmission) -> some View {
        switch proof.verdict {
        case nil: Label("Checking", systemImage: "clock").foregroundStyle(.orange)
        case .accepted, .guardianApproved: Label("Accepted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .rejected: Label("Not accepted", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .error: Label("Couldn't check", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// "1 point", "10 points", "2.5 points".
    private func pointsText(_ points: Double) -> String {
        let number = points == points.rounded() ? String(Int(points)) : String(format: "%g", points)
        return points == 1 ? "1 point" : "\(number) points"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var instructionsHTML: String {
        if case let .loaded(page) = model.details[taskID] { return page.instructionsHTML }
        return ""
    }

    /// The assignment's own page once it's loaded, or else the Assignment Center.
    private func blackbaudPage(_ task: TaxTask) -> URL? {
        if case let .loaded(page) = model.details[taskID] { return page.pageURL }
        guard task.isFromBlackbaud, let host = model.feedURL?.host else { return nil }
        return URL(string: "https://\(host)/lms-assignment/assignment-center/student")
    }
}

/// Turns the teacher's HTML (or plain text) into text with working links, in the window's own font and colors.
/// The HTML import spins WebKit up, so the view runs it once per page, never while drawing.
@MainActor
enum RichText {
    static func fromHTML(_ html: String) -> AttributedString? {
        // The import turns <br> and the end of a paragraph into the same "\n", so mark <br> first.
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "&#x2028;", options: [.regularExpression, .caseInsensitive])
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let text = try? NSMutableAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil)
        else { return nil }
        tidy(text)
        guard text.length > 0 else { return nil }
        // Keep the teacher's links, bold and italics; the font and colors follow the window.
        var result = AttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = AttributedString(text.attributedSubstring(from: range).string)
            if let link = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:)) {
                piece.link = link
            }
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var intent: InlinePresentationIntent = []
            if traits.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if traits.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            result += piece
        }
        return result
    }

    /// Without the page's styles, list items come out as "\t•\tText" and paragraphs run together.
    /// Indent the items a little, and leave a blank line between paragraphs but not between list items.
    private static func tidy(_ text: NSMutableAttributedString) {
        // How deep an item is nested is only in its paragraph style.
        if let items = try? NSRegularExpression(pattern: #"(?m)^\t+([^\t\n]{1,6})\t"#) {
            let source = text.string as NSString
            for match in items.matches(in: source as String, range: NSRange(location: 0, length: source.length)).reversed() {
                var marker = source.substring(with: match.range(at: 1))
                if let last = marker.last, last.isLetter || last.isNumber { marker += "." }
                let style = text.attribute(.paragraphStyle, at: match.range.location, effectiveRange: nil) as? NSParagraphStyle
                let depth = max(style?.textLists.count ?? 1, 1)
                text.replaceCharacters(in: match.range, with: String(repeating: "    ", count: depth - 1) + "   \(marker) ")
            }
        }
        replace(#"(?m)^[ \t ]+$"#, in: text) { _ in "" }
        let lines = text.string.components(separatedBy: "\n")
        var newline = text.length
        for i in stride(from: lines.count - 1, through: 1, by: -1) {
            newline -= (lines[i] as NSString).length + 1
            let sameList = lines[i].hasPrefix("   ") && lines[i - 1].hasPrefix("   ")
            if !lines[i].isEmpty && !lines[i - 1].isEmpty && !sameList {
                text.insert(NSAttributedString(string: "\n"), at: newline)
            }
        }
        // <br> came through as U+2028 so it wouldn't count as a paragraph; now it's an ordinary line break.
        replace("\u{2028}", in: text) { _ in "\n" }
        replace(#"(?m)^[ \t ]+$"#, in: text) { _ in "" }
        replace(#"\n{3,}"#, in: text) { _ in "\n\n" }
        let s = text.string as NSString
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        let first = s.rangeOfCharacter(from: visible)
        guard first.location != NSNotFound else {
            text.deleteCharacters(in: NSRange(location: 0, length: text.length))
            return
        }
        let last = s.rangeOfCharacter(from: visible, options: .backwards)
        text.deleteCharacters(in: NSRange(location: NSMaxRange(last), length: s.length - NSMaxRange(last)))
        // Blank lines go from the top, but not the indent of a list item that starts the text.
        let lineBreak = s.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: first.location))
        text.deleteCharacters(in: NSRange(location: 0, length: lineBreak.location == NSNotFound ? 0 : NSMaxRange(lineBreak)))
    }

    /// Replaces each match (last first, so earlier ranges stay put). `make` gets the first capture group.
    private static func replace(_ pattern: String, in text: NSMutableAttributedString, make: (String) -> String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let source = text.string as NSString
        for match in regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)).reversed() {
            let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                ? source.substring(with: match.range(at: 1)) : ""
            text.replaceCharacters(in: match.range, with: make(group))
        }
    }

    /// Plain text with any web addresses made clickable.
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let r = Range(match.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: result),
                  let upper = AttributedString.Index(r.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// Clicking a task's row opens its details. The row lights up under the pointer so you can tell it does.
private struct OpensDetails: ViewModifier {
    @Environment(AppModel.self) private var model
    let taskID: UUID
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { model.onOpenDetails(taskID) }
            .onHover { hovered = $0 }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
                    .padding(.horizontal, 6))
    }
}

extension View {
    func opensDetails(_ taskID: UUID) -> some View { modifier(OpensDetails(taskID: taskID)) }
}
