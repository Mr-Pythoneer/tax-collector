import SwiftUI
import TaxCore

/// A tax-office ledger look: serif headings, tabular numbers, one stamp red and one paid green.
enum Theme {
    static let stamp = Color(red: 0.70, green: 0.15, blue: 0.12)
    static let paid = Color(red: 0.18, green: 0.45, blue: 0.27)
    static let amber = Color(red: 0.72, green: 0.48, blue: 0.08)

    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .semibold, design: .serif) }
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

extension TaxTask {
    func stamp(now: Date, checking: Bool) -> (String, Color) {
        if checking { return ("CHECKING", Theme.amber) }
        switch status {
        case .pending:
            return dueDate <= now ? ("OVERDUE", Theme.stamp) : ("OWED", .secondary)
        case .proven: return ("PAID", Theme.paid)
        case let .provenLate(_, end):
            return end > now ? ("LATE FEE", Theme.stamp) : ("PAID LATE", Theme.paid)
        case .excused: return ("EXCUSED", .secondary)
        }
    }
}
