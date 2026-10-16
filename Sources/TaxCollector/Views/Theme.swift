import AppKit
import SwiftUI
import TaxCore

/// A planner on paper: warm paper and ink instead of white-on-grey, a serif for headings,
/// tabular numbers for times, a stamp red and a paid green, and one steady colour per class.
/// Every colour has a Paper (light) and an Ink (dark) version.
enum Theme {
    static let stamp = dynamic(0xB3261E, 0xFF6B5E)
    static let paid = dynamic(0x2E7346, 0x6CCB8C)
    static let amber = dynamic(0xA9660A, 0xF2B544)
    /// Solid red for bars with white text on them; stays deep in both looks so the text reads.
    static let stampFill = dynamic(0xB3261E, 0xA8322A)

    /// The window background: warm paper, or a soft ink rather than black.
    static let paper = dynamic(0xF4EFE4, 0x17191E)
    /// Rows and cards sit a step lighter than the paper.
    static let card = dynamic(0xFFFCF6, 0x22252C)
    static let ink = dynamic(0x1E2330, 0xEEE7DA)
    static let inkSoft = dynamic(0x596071, 0xA9ACB4)
    static let rule = dynamic(0xE1D7C3, 0x30343D)

    /// Class colours, muted enough for paper and lifted for ink. No purple.
    static let courseColors: [Color] = [
        dynamic(0x2D6CB0, 0x6FA8F0),  // blue
        dynamic(0x1E8178, 0x4FC9BC),  // teal
        dynamic(0x3D7F2F, 0x86C96F),  // green
        dynamic(0xB4621A, 0xF0A15B),  // orange
        dynamic(0xA8324B, 0xF07A93),  // rose
        dynamic(0x6B6A1D, 0xC9C55A),  // olive
        dynamic(0x7A4E2D, 0xD3A07A),  // brown
        dynamic(0x465870, 0x9DB0C9),  // slate
    ]

    static func courseColor(_ course: String) -> Color {
        courseColors[Agenda.colorSlot(for: course, slots: courseColors.count)]
    }

    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .semibold, design: .serif) }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Paper by default; you can switch to Ink, or follow the Mac.
    static func apply(_ appearance: String) {
        switch appearance {
        case "ink": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .aqua)
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

    static func due(_ task: TaxTask, now: Date) -> String {
        let left = task.dueDate.timeIntervalSince(now)
        return left > 0 ? "due in \(span(left))" : "overdue by \(span(left))"
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

/// A small rubber-stamp label.
struct StampLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1.2))
    }
}

/// The class name in its colour, like a tab on a binder divider.
struct CourseTag: View {
    let course: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.courseColor(course))
                .frame(width: 8, height: 8)
            Text(course.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.courseColor(course))
                .lineLimit(1)
        }
    }
}

extension TaxTask {
    func stamp(now: Date, checking: Bool) -> (String, Color) {
        if checking { return ("CHECKING", Theme.amber) }
        switch status {
        case .pending:
            return dueDate <= now ? ("OVERDUE", Theme.stamp) : ("OWED", Theme.inkSoft)
        case .proven: return ("PAID", Theme.paid)
        case let .provenLate(_, end):
            return end > now ? ("LATE FEE", Theme.stamp) : ("PAID LATE", Theme.paid)
        case .excused: return ("EXCUSED", Theme.inkSoft)
        }
    }

    /// Red once it's late, amber inside a day, plain ink after that.
    func urgencyColor(now: Date) -> Color {
        let left = dueDate.timeIntervalSince(now)
        if left <= 0 { return Theme.stamp }
        if left <= 24 * 3600 { return Theme.amber }
        return Theme.ink
    }
}
