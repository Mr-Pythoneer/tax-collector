import AppKit
import SwiftUI
import TaxCore

/// System colors and fonts throughout, so the app looks like it belongs on a Mac.
enum Theme {
    /// One dot color per class, like calendars in Calendar. Red is left out: it means overdue.
    static let courseColors: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemGreen), Color(nsColor: .systemOrange),
        Color(nsColor: .systemTeal), Color(nsColor: .systemPink), Color(nsColor: .systemBrown),
        Color(nsColor: .systemMint), Color(nsColor: .systemYellow),
    ]

    static func courseColor(_ course: String) -> Color {
        courseColors[Agenda.colorSlot(for: course, slots: courseColors.count)]
    }

    /// Picked from the full class name ("Mathematics 7 - MAT7 - 7B"), so two maths classes
    /// usually get different dots even though both show as "Mathematics".
    static func courseColor(for task: TaxTask) -> Color? {
        guard task.isImported, let course = BlackbaudMatch.split(task.title).course else { return nil }
        return courseColor(course)
    }

    /// Light by default (dark text on white is easier to read), or Dark, or whatever the Mac uses.
    /// "paper" and "ink" are the names older versions saved.
    static func apply(_ appearance: String) {
        switch appearance {
        case "dark", "ink": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    static func appearanceName(_ saved: String) -> String {
        switch saved {
        case "dark", "ink": "dark"
        case "system": "system"
        default: "light"
        }
    }
}

enum Fmt {
    /// "3d 4h", "2h 05m", "12m 30s", "40s".
    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds).rounded(.down))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m \(String(format: "%02d", sec))s" }
        return "\(sec)s"
    }

    /// "in 2h 05m" or "12m ago".
    static func relative(_ date: Date, now: Date) -> String {
        let left = date.timeIntervalSince(now)
        return left > 0 ? "in \(span(left))" : "\(span(left)) ago"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func formatted(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}

/// The class as a colored dot and its name.
struct CourseLabel: View {
    let course: String
    let color: Color

    init(_ task: TaxTask) {
        course = Agenda.courseAndTitle(task).course ?? ""
        color = Theme.courseColor(for: task) ?? .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(course)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
    }
}

extension TaxTask {
    /// A short word for where the task stands, and its color.
    func statusWord(now: Date, checking: Bool) -> (String, Color) {
        if checking { return ("Checking proof", .orange) }
        switch status {
        case .pending:
            return dueDate <= now ? ("Overdue", .red) : ("To do", .secondary)
        case .proven: return ("Done", .green)
        case let .provenLate(_, end):
            return end > now ? ("Late penalty", .red) : ("Done late", .green)
        case .excused: return ("Excused", .secondary)
        }
    }

    /// Red once it's late, orange within a day, otherwise the normal secondary color.
    func urgencyColor(now: Date) -> Color {
        let left = dueDate.timeIntervalSince(now)
        if left <= 0 { return .red }
        if left <= 24 * 3600 { return .orange }
        return .secondary
    }
}
