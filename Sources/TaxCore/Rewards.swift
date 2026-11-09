import Foundation

// Credits, free time, the watchlist, research passes and the wishlist.
// 1 credit = 30 minutes of free time. Credits are earned when a task's proof is accepted: more for
// bigger, better work done earlier, nothing for late work.

/// How much work a task was, as the auditor judged it.
public enum WorkSize: String, Codable, Equatable, Sendable, CaseIterable {
    case small
    case medium
    case large

    public var credits: Double {
        switch self {
        case .small: 1
        case .medium: 2
        case .large: 3
        }
    }
}

/// What one credit buys.
public enum Credits {
    public static let secondsPerCredit: TimeInterval = 30 * 60
    /// Free time is bought in 15-minute steps.
    public static let step = 0.5
    public static let earnRateRange: ClosedRange<Double> = 0.5...2

    public static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// "1.5 credits"
    public static func format(_ value: Double) -> String {
        let v = rounded(value)
        let text = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        return "\(text) credit\(v == 1 ? "" : "s")"
    }

    /// "1 h 15 min", "45 min", "40 s"
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = (s + 30) / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}

/// What a task earned, and why.
public struct Earning: Equatable, Sendable {
    public var credits: Double
    public var size: WorkSize
    public var grade: Int
    /// 1 right after the task was set, down to 0.25 at the deadline, 0 when late.
    public var timing: Double

    public var note: String {
        "\(size.rawValue), grade \(grade), \(Int((timing * 100).rounded()))% for timing"
    }
}

/// One move of credits in or out of the wallet.
public struct LedgerEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Proof accepted.
        case earned
        /// Turned into time left.
        case freeTime
        /// Spent on something from the wishlist.
        case wish
        /// A wishlist item given back.
        case refund
        /// Added or taken by the guardian.
        case guardian
    }

    public var id: UUID
    public var at: Date
    /// Positive in, negative out.
    public var amount: Double
    public var kind: Kind
    public var note: String
    public var taskID: UUID?
    public var wishID: UUID?

    public init(id: UUID = UUID(), at: Date, amount: Double, kind: Kind, note: String,
                taskID: UUID? = nil, wishID: UUID? = nil) {
        self.id = id
        self.at = at
        self.amount = amount
        self.kind = kind
        self.note = note
        self.taskID = taskID
        self.wishID = wishID
    }
}

/// Bought free time. While signed in it counts down and every watchlist item is open.
public struct FreeTime: Codable, Equatable, Sendable {
    public var secondsLeft: TimeInterval
    /// nil while signed out.
    public var signedInAt: Date?
    /// The last time something on the watchlist was in front while signed in.
    public var lastWatchedAt: Date?
    /// Set once the one-minute warning has been given for this sign-in.
    public var warned: Bool

    public init(secondsLeft: TimeInterval = 0, signedInAt: Date? = nil, lastWatchedAt: Date? = nil, warned: Bool = false) {
        self.secondsLeft = secondsLeft
        self.signedInAt = signedInAt
        self.lastWatchedAt = lastWatchedAt
        self.warned = warned
    }

    public var isSignedIn: Bool { signedInAt != nil }
}

/// A site or an app on the watchlist.
public struct WatchItem: Codable, Identifiable, Equatable, Sendable {
    public enum Target: Codable, Equatable, Hashable, Sendable {
        /// A domain like "youtube.com": it and its subdomains.
        case site(domain: String)
        /// An app by bundle ID, or "proc:<name>" for a program without one (Minecraft runs as Java).
        case app(id: String, name: String)
    }

    public var id: UUID
    public var target: Target
    public var addedAt: Date
    /// You asked to take it off; it stays watched until then.
    public var removeAt: Date?

    public init(id: UUID = UUID(), target: Target, addedAt: Date, removeAt: Date? = nil) {
        self.id = id
        self.target = target
        self.addedAt = addedAt
        self.removeAt = removeAt
    }

    public var name: String {
        switch target {
        case let .site(domain): domain
        case let .app(_, name): name
        }
    }

    public var isSite: Bool {
        if case .site = target { return true }
        return false
    }
}

/// What's in front right now, as far as the watchlist cares.
public struct FrontThing: Equatable, Sendable {
    public var bundleID: String?
    /// The app's name as the system shows it, and its executable's name.
    public var appName: String
    public var processName: String
    /// The front tab's address, when the front app is a browser that tells us.
    public var url: String?
    /// The front window's title, for browsers that don't give their address.
    public var windowTitle: String?

    public init(bundleID: String?, appName: String, processName: String, url: String? = nil, windowTitle: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.processName = processName
        self.url = url
        self.windowTitle = windowTitle
    }
}

public enum PassDecision: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case error
}

/// "I need it for school": a request to use one watched site or app for a task, decided by Claude.
public struct ResearchPass: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var itemName: String
    public var taskID: UUID
    public var taskTitle: String
    public var reason: String
    public var askedAt: Date
    /// nil while Claude is deciding.
    public var decision: PassDecision?
    public var minutes: Int
    public var answer: String
    /// When a granted pass runs out.
    public var until: Date?

    public init(id: UUID = UUID(), itemID: UUID, itemName: String, taskID: UUID, taskTitle: String, reason: String,
                askedAt: Date, decision: PassDecision? = nil, minutes: Int = 0, answer: String = "", until: Date? = nil) {
        self.id = id
        self.itemID = itemID
        self.itemName = itemName
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.reason = reason
        self.askedAt = askedAt
        self.decision = decision
        self.minutes = minutes
        self.answer = answer
        self.until = until
    }

    public func isActive(at now: Date) -> Bool { decision == .granted && (until.map { $0 > now } ?? false) }
}

/// Something you want, priced in credits.
public struct WishItem: Codable, Identifiable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        /// Claude is pricing it.
        case pricing
        /// Pricing didn't work; you can try again.
        case unpriced(reason: String)
        case priced
        case bought(at: Date)
        case given(at: Date)
        case refunded(at: Date)
    }

    public var id: UUID
    public var name: String
    /// What it costs in real money, as you typed it ("$25", "¥180").
    public var realPrice: String
    public var note: String
    public var addedAt: Date
    public var credits: Double?
    public var priceReason: String
    /// What it costs in US dollars, read from `realPrice` (by Claude when it's another currency or vague).
    /// The credit price is worked out from this at the guardian's rate. nil for older items.
    public var usd: Double?
    /// "Claude" or "your guardian".
    public var pricedBy: String
    public var state: State

    public init(id: UUID = UUID(), name: String, realPrice: String, note: String = "", addedAt: Date,
                credits: Double? = nil, priceReason: String = "", pricedBy: String = "", state: State = .pricing) {
        self.id = id
        self.name = name
        self.realPrice = realPrice
        self.note = note
        self.addedAt = addedAt
        self.credits = credits
        self.priceReason = priceReason
        self.pricedBy = pricedBy
        self.state = state
    }

    public var canBuy: Bool { state == .priced && credits != nil }
}

/// Everything about credits, saved as rewards.json.
public struct RewardsState: Codable, Equatable, Sendable {
    public var ledger: [LedgerEntry]
    public var freeTime: FreeTime
    public var passes: [ResearchPass]
    public var wishes: [WishItem]
    public var watchlist: [WatchItem]

    public init(ledger: [LedgerEntry] = [], freeTime: FreeTime = FreeTime(), passes: [ResearchPass] = [],
                wishes: [WishItem] = [], watchlist: [WatchItem] = []) {
        self.ledger = ledger
        self.freeTime = freeTime
        self.passes = passes
        self.wishes = wishes
        self.watchlist = watchlist
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ledger = try c.decodeIfPresent([LedgerEntry].self, forKey: .ledger) ?? []
        freeTime = try c.decodeIfPresent(FreeTime.self, forKey: .freeTime) ?? FreeTime()
        passes = try c.decodeIfPresent([ResearchPass].self, forKey: .passes) ?? []
        wishes = try c.decodeIfPresent([WishItem].self, forKey: .wishes) ?? []
        watchlist = try c.decodeIfPresent([WatchItem].self, forKey: .watchlist) ?? []
    }

    public var balance: Double { Credits.rounded(ledger.reduce(0) { $0 + $1.amount }) }

    public func hasEarned(taskID: UUID) -> Bool {
        ledger.contains { $0.kind == .earned && $0.taskID == taskID }
    }
}

/// Why something can't be done right now.
public enum RewardsRefusal: Error, Equatable, Sendable {
    case locked
    case notEnoughCredits
    case badAmount
    case noTimeLeft
    case tooManyPasses
    case notWatched

    public var message: String {
        switch self {
        case .locked: "Not during a lock. Pay off what's overdue first."
        case .notEnoughCredits: "You don't have enough credits."
        case .badAmount: "Free time comes in 15-minute steps."
        case .noTimeLeft: "You have no time left. Buy some first."
        case .tooManyPasses: "That task has had \(Rewards.passesPerTaskPerDay) passes today already."
        case .notWatched: "That isn't on your watchlist."
        }
    }
}

public enum Rewards {
    /// Free time signs out after this long with nothing from the watchlist in front.
    public static let idleSignOut: TimeInterval = 5 * 60
    public static let warnBefore: TimeInterval = 60
    /// A tick counts at most this much, so a sleeping Mac doesn't eat your time.
    public static let maxTick: TimeInterval = 5
    public static let removeDelay: TimeInterval = 24 * 3600
    /// Something added by mistake can be taken off at once for this long.
    public static let addGrace: TimeInterval = 5 * 60
    public static let passesPerTaskPerDay = 3
    public static let maxPassMinutes = 60
    /// What a guardian approval counts as.
    public static let guardianGrade = 70
    /// When the auditor gave no grade or size (an older answer).
    public static let defaultGrade = 70
    public static let defaultSize = WorkSize.medium
    /// Shortest time from setting a task to its deadline that timing is measured over.
    public static let minimumWindow: TimeInterval = 3600

    // MARK: Earning

    /// The deadline that counts for timing: the first one, before any extension.
    public static func originalDue(_ task: TaxTask) -> Date {
        ((task.extensions ?? []).map(\.previousDue) + [task.dueDate]).min() ?? task.dueDate
    }

    /// 1 when submitted right after the task was set, sliding to 0.25 at the deadline; 0 when late.
    public static func timing(createdAt: Date, due: Date, submittedAt: Date) -> Double {
        guard submittedAt <= due else { return 0 }
        let window = max(due.timeIntervalSince(createdAt), minimumWindow)
        let left = min(max(due.timeIntervalSince(submittedAt), 0), window)
        return 0.25 + 0.75 * left / window
    }

    /// What accepting `proof` earns. nil when it earns nothing: late, excused, not accepted.
    public static func earning(task: TaxTask, proof: ProofSubmission, earnRate: Double) -> Earning? {
        guard proof.isAccepted else { return nil }
        if case .provenLate = task.status { return nil }
        if case .excused = task.status { return nil }
        let grade = min(max(proof.verdict == .guardianApproved ? (proof.grade ?? guardianGrade) : (proof.grade ?? defaultGrade), 0), 100)
        let size = proof.size ?? defaultSize
        let timing = timing(createdAt: task.createdAt, due: originalDue(task), submittedAt: proof.submittedAt)
        guard timing > 0 else { return nil }
        let rate = min(max(earnRate, Credits.earnRateRange.lowerBound), Credits.earnRateRange.upperBound)
        let credits = Credits.rounded(size.credits * Double(grade) / 100 * timing * rate)
        guard credits > 0 else { return nil }
        return Earning(credits: credits, size: size, grade: grade, timing: timing)
    }

    /// Credits earned per week over the last four weeks, for pricing the wishlist. nil with no history.
    public static func weeklyEarning(_ state: RewardsState, now: Date) -> Double? {
        let since = now.addingTimeInterval(-28 * 24 * 3600)
        let earned = state.ledger.filter { $0.kind == .earned && $0.at > since }
        guard let first = earned.map(\.at).min() else { return nil }
        let weeks = max(1, now.timeIntervalSince(first) / (7 * 24 * 3600))
        return Credits.rounded(earned.reduce(0) { $0 + $1.amount } / min(weeks, 4))
    }

    // MARK: Free time

    /// Turns credits into time left.
    public static func buyTime(_ state: inout RewardsState, credits: Double, locked: Bool, now: Date) -> RewardsRefusal? {
        if locked { return .locked }
        let steps = credits / Credits.step
        guard credits > 0, abs(steps - steps.rounded()) < 0.001 else { return .badAmount }
        guard state.balance + 0.0001 >= credits else { return .notEnoughCredits }
        state.ledger.append(LedgerEntry(at: now, amount: -credits, kind: .freeTime,
                                        note: "\(Credits.duration(credits * Credits.secondsPerCredit)) of free time"))
        state.freeTime.secondsLeft += credits * Credits.secondsPerCredit
        return nil
    }

    public static func signIn(_ state: inout RewardsState, locked: Bool, now: Date) -> RewardsRefusal? {
        if locked { return .locked }
        guard state.freeTime.secondsLeft > 0 else { return .noTimeLeft }
        if state.freeTime.signedInAt == nil {
            state.freeTime.signedInAt = now
            state.freeTime.lastWatchedAt = now
            state.freeTime.warned = state.freeTime.secondsLeft <= warnBefore
        }
        return nil
    }

    public static func signOut(_ state: inout RewardsState) {
        state.freeTime.signedInAt = nil
        state.freeTime.lastWatchedAt = nil
        state.freeTime.warned = false
    }

    public enum TickEvent: Equatable, Sendable {
        case warnOneMinute
        case ranOut
        case idleSignedOut
        case lockSignedOut
    }

    /// Runs the clock while signed in. `elapsed` is the time since the last tick; `watchedInFront` says whether
    /// something on the watchlist is in front.
    public static func tick(_ state: inout RewardsState, elapsed: TimeInterval, watchedInFront: Bool, locked: Bool,
                            now: Date) -> TickEvent? {
        guard state.freeTime.isSignedIn else { return nil }
        if locked {
            signOut(&state)
            return .lockSignedOut
        }
        state.freeTime.secondsLeft = max(0, state.freeTime.secondsLeft - min(max(elapsed, 0), maxTick))
        if watchedInFront { state.freeTime.lastWatchedAt = now }
        if state.freeTime.secondsLeft <= 0 {
            signOut(&state)
            return .ranOut
        }
        if let last = state.freeTime.lastWatchedAt, now.timeIntervalSince(last) >= idleSignOut {
            signOut(&state)
            return .idleSignedOut
        }
        if !state.freeTime.warned && state.freeTime.secondsLeft <= warnBefore {
            state.freeTime.warned = true
            return .warnOneMinute
        }
        return nil
    }

    // MARK: Watchlist

    /// "https://www.YouTube.com/watch?v=1" → "youtube.com". nil when it doesn't look like a domain.
    public static func normalizeDomain(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let cut = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<cut]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } })
        else { return nil }
        return s
    }

    /// The host of an address, lowercased, or nil.
    public static func host(of url: String) -> String? {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    public static func siteMatches(domain: String, url: String) -> Bool {
        guard let host = host(of: url) else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// For browsers that only give a window title: "Cats - YouTube — Mozilla Firefox" matches youtube.com.
    public static func siteMatches(domain: String, title: String) -> Bool {
        let word = domain.split(separator: ".").dropLast().last.map(String.init) ?? domain
        guard word.count >= 3 else { return false }
        return title.lowercased().range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                                        options: .regularExpression) != nil
    }

    /// Bundle ID or "proc:<name>" for an app picked from what's running.
    public static func appID(bundleID: String?, processName: String) -> String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return "proc:\(processName.lowercased())"
    }

    /// The first watchlist item that matches what's in front.
    public static func match(_ front: FrontThing, watchlist: [WatchItem], isBrowser: Bool) -> WatchItem? {
        for item in watchlist {
            switch item.target {
            case let .app(id, _):
                if id.hasPrefix("proc:") {
                    let name = String(id.dropFirst(5))
                    if front.processName.lowercased() == name || front.appName.lowercased() == name { return item }
                } else if front.bundleID == id {
                    return item
                }
            case let .site(domain):
                guard isBrowser else { continue }
                if let url = front.url {
                    if siteMatches(domain: domain, url: url) { return item }
                } else if let title = front.windowTitle, siteMatches(domain: domain, title: title) {
                    return item
                }
            }
        }
        return nil
    }

    /// Whether `item` is open right now without a checkpoint.
    public static func isOpen(_ item: WatchItem, state: RewardsState, now: Date) -> Bool {
        state.freeTime.isSignedIn || activePass(for: item.id, state: state, now: now) != nil
    }

    public static func activePass(for itemID: UUID, state: RewardsState, now: Date) -> ResearchPass? {
        state.passes.last { $0.itemID == itemID && $0.isActive(at: now) }
    }

    public static func add(_ target: WatchItem.Target, to state: inout RewardsState, now: Date) -> WatchItem? {
        if let i = state.watchlist.firstIndex(where: { $0.target == target }) {
            // Asking to add something that's on its way off keeps it.
            state.watchlist[i].removeAt = nil
            return nil
        }
        let item = WatchItem(target: target, addedAt: now)
        state.watchlist.append(item)
        return item
    }

    public enum RemoveResult: Equatable, Sendable {
        case removed
        case scheduled(at: Date)
    }

    /// Takes an item off: at once with the guardian or if it was only just added, otherwise in 24 hours.
    public static func remove(_ itemID: UUID, from state: inout RewardsState, guardian: Bool, now: Date) -> RemoveResult? {
        guard let i = state.watchlist.firstIndex(where: { $0.id == itemID }) else { return nil }
        if guardian || now.timeIntervalSince(state.watchlist[i].addedAt) < addGrace {
            state.watchlist.remove(at: i)
            return .removed
        }
        let at = state.watchlist[i].removeAt ?? now.addingTimeInterval(removeDelay)
        state.watchlist[i].removeAt = at
        return .scheduled(at: at)
    }

    /// Drops the items whose 24 hours are up. Returns their names.
    public static func pruneRemovals(_ state: inout RewardsState, now: Date) -> [String] {
        let gone = state.watchlist.filter { ($0.removeAt.map { $0 <= now }) ?? false }
        guard !gone.isEmpty else { return [] }
        state.watchlist.removeAll { ($0.removeAt.map { $0 <= now }) ?? false }
        return gone.map(\.name)
    }

    // MARK: Research passes

    /// Passes asked for this task in the last day (not counting ones that couldn't be decided).
    public static func passesToday(taskID: UUID, state: RewardsState, now: Date) -> Int {
        state.passes.filter { $0.taskID == taskID && $0.decision != .error && now.timeIntervalSince($0.askedAt) < 24 * 3600 }.count
    }

    /// Minutes already granted for this task, for Claude to weigh.
    public static func minutesGranted(taskID: UUID, state: RewardsState) -> Int {
        state.passes.filter { $0.taskID == taskID && $0.decision == .granted }.reduce(0) { $0 + $1.minutes }
    }

    public static func canAskPass(taskID: UUID, state: RewardsState, now: Date) -> RewardsRefusal? {
        passesToday(taskID: taskID, state: state, now: now) >= passesPerTaskPerDay ? .tooManyPasses : nil
    }

    // MARK: Wishlist

    /// How many dollars of wishlist buy one credit, unless the guardian changes it.
    public static let defaultDollarsPerCredit = 5.0
    public static let dollarsPerCreditRange: ClosedRange<Double> = 1...50
    /// Weekly earning assumed for the "about N weeks" note when there's no history yet.
    public static let assumedWeeklyEarning = 10.0

    /// A plain US-dollar price ("$649.95", "~150$", "about 1,200", "265 USD"), read without asking Claude.
    /// nil for anything else (another currency, a range, words).
    public static func localUSD(_ text: String) -> Double? {
        let pattern = #"^\s*(?:~|≈|about|around|approx\.?|roughly)?\s*(?:US\s?)?\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*\$?\s*(?:USD|dollars?|bucks)?\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text),
              let value = Double(text[r].replacingOccurrences(of: ",", with: "")), value > 0 else { return nil }
        return value
    }

    /// The price in credits: dollars ÷ dollars per credit, rounded, never under 1.
    public static func wishCredits(usd: Double, dollarsPerCredit: Double) -> Double {
        let rate = min(max(dollarsPerCredit, dollarsPerCreditRange.lowerBound), dollarsPerCreditRange.upperBound)
        return max(1, (usd / rate).rounded())
    }

    /// "$649.95 at $5 a credit = 130 credits, about 13 weeks of your usual earning."
    public static func wishReason(usd: Double, dollarsPerCredit: Double, weeklyEarning: Double?, note: String = "") -> String {
        let credits = wishCredits(usd: usd, dollarsPerCredit: dollarsPerCredit)
        let weekly = weeklyEarning.flatMap { $0 > 0 ? $0 : nil }
        let weeks = credits / (weekly ?? assumedWeeklyEarning)
        let weeksText = weeks < 1 ? "under a week" : "about \(Int(weeks.rounded())) week\(Int(weeks.rounded()) == 1 ? "" : "s")"
        let earning = weekly == nil ? "at \(Int(assumedWeeklyEarning)) credits a week" : "of your usual earning"
        let lead = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead.isEmpty ? "" : lead.hasSuffix(".") ? lead + " " : lead + ". ")
            + "\(dollars(usd)) at \(dollars(dollarsPerCredit)) a credit = \(Credits.format(credits)), \(weeksText) \(earning)."
    }

    public static func dollars(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
    }

    public static func buy(_ wishID: UUID, state: inout RewardsState, locked: Bool, now: Date) -> RewardsRefusal? {
        if locked { return .locked }
        guard let i = state.wishes.firstIndex(where: { $0.id == wishID }), state.wishes[i].canBuy,
              let price = state.wishes[i].credits else { return .badAmount }
        guard state.balance + 0.0001 >= price else { return .notEnoughCredits }
        state.ledger.append(LedgerEntry(at: now, amount: -price, kind: .wish, note: state.wishes[i].name, wishID: wishID))
        state.wishes[i].state = .bought(at: now)
        return nil
    }

    /// The guardian hands it over, or gives the credits back.
    public static func settle(_ wishID: UUID, given: Bool, state: inout RewardsState, now: Date) {
        guard let i = state.wishes.firstIndex(where: { $0.id == wishID }), case .bought = state.wishes[i].state else { return }
        if given {
            state.wishes[i].state = .given(at: now)
        } else {
            let paid = -(state.ledger.last { $0.kind == .wish && $0.wishID == wishID }?.amount ?? 0)
            if paid > 0 {
                state.ledger.append(LedgerEntry(at: now, amount: paid, kind: .refund, note: state.wishes[i].name, wishID: wishID))
            }
            state.wishes[i].state = .refunded(at: now)
        }
    }
}
