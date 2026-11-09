import AppKit
import TaxCore

/// Credits, free time, the watchlist, research passes and the wishlist (rules in TaxCore/Rewards.swift).
extension AppModel {
    var balance: Double { rewards.balance }
    var freeTimeLeft: TimeInterval { rewards.freeTime.secondsLeft }
    var isSignedIn: Bool { rewards.freeTime.isSignedIn }

    func saveRewards() { store.saveRewards(rewards) }

    /// Pending tasks, soonest first, for "I need it for school".
    var tasksForPasses: [TaxTask] { tasks.filter(\.isPending).sorted { $0.dueDate < $1.dueDate } }

    // MARK: Earning

    /// Called when a proof is accepted. Pays once per task.
    func awardCredits(taskID: UUID, submissionID: UUID) {
        guard let t = task(taskID), let proof = t.proofs.first(where: { $0.id == submissionID }),
              !rewards.hasEarned(taskID: taskID) else { return }
        guard let earning = Rewards.earning(task: t, proof: proof, earnRate: settings.earnRate) else {
            store.log("CREDITS none for \"\(t.title)\" (late, excused or graded 0)")
            return
        }
        rewards.ledger.append(LedgerEntry(at: now, amount: earning.credits, kind: .earned,
                                          note: "\(t.title) (\(earning.note))", taskID: taskID))
        saveRewards()
        store.log("CREDITS +\(earning.credits) for \"\(t.title)\": \(earning.note)")
        onRewardsNotice("You earned \(Credits.format(earning.credits)) for \(t.title).")
    }

    // MARK: Free time

    /// nil when it worked, otherwise why not.
    @discardableResult
    func buyTime(credits: Double) -> String? {
        if let refusal = Rewards.buyTime(&rewards, credits: credits, locked: lock.isLocked, now: now) { return refusal.message }
        saveRewards()
        store.log("CREDITS -\(credits) for \(Credits.duration(credits * Credits.secondsPerCredit)) of free time")
        return nil
    }

    /// Buys time and signs in, as one step from the checkpoint.
    @discardableResult
    func buyTimeAndSignIn(credits: Double) -> String? {
        if let why = buyTime(credits: credits) { return why }
        return signIn()
    }

    @discardableResult
    func signIn() -> String? {
        let was = isSignedIn
        if let refusal = Rewards.signIn(&rewards, locked: lock.isLocked, now: now) { return refusal.message }
        saveRewards()
        if !was { store.log("FREE TIME signed in, \(Credits.duration(freeTimeLeft)) left") }
        lastRewardsTick = now
        onRewardsChanged()
        return nil
    }

    func signOut(reason: String = "you signed out") {
        guard isSignedIn else { return }
        Rewards.signOut(&rewards)
        saveRewards()
        store.log("FREE TIME signed out (\(reason)), \(Credits.duration(freeTimeLeft)) left")
        onRewardsChanged()
    }

    /// Runs from `tick()`.
    func tickRewards() {
        let elapsed = lastRewardsTick.map { now.timeIntervalSince($0) } ?? 0
        lastRewardsTick = now
        let removed = Rewards.pruneRemovals(&rewards, now: now)
        if !removed.isEmpty {
            saveRewards()
            store.log("WATCHLIST took off \(removed.joined(separator: ", ")) (24 hours were up)")
        }
        let event = Rewards.tick(&rewards, elapsed: elapsed, watchedInFront: watchedInFront != nil,
                                 locked: lock.isLocked, now: now)
        if isSignedIn, now.timeIntervalSince(lastRewardsSave) >= 15 {
            saveRewards()
            lastRewardsSave = now
        }
        guard let event else { return }
        saveRewards()
        switch event {
        case .warnOneMinute:
            onRewardsNotice("1 minute of free time left.")
        case .ranOut:
            store.log("FREE TIME ran out")
            onRewardsNotice("Your free time is up.")
        case .idleSignedOut:
            store.log("FREE TIME signed out: nothing on the watchlist for 5 minutes, \(Credits.duration(freeTimeLeft)) left")
            onRewardsNotice("Signed out of free time to save it: \(Credits.duration(freeTimeLeft)) left.")
        case .lockSignedOut:
            store.log("FREE TIME signed out by a lock, \(Credits.duration(freeTimeLeft)) left")
        }
        onRewardsChanged()
    }

    // MARK: Watchlist

    var watchlist: [WatchItem] { rewards.watchlist }

    /// nil when added, otherwise why not.
    func addSite(_ input: String) -> String? {
        guard let domain = Rewards.normalizeDomain(input) else { return "That doesn't look like a website, like youtube.com." }
        return addWatch(.site(domain: domain))
    }

    func addApp(id: String, name: String) -> String? {
        if id == selfBundleID { return "Tax Collector can't watch itself." }
        return addWatch(.app(id: id, name: name))
    }

    private func addWatch(_ target: WatchItem.Target) -> String? {
        let added = Rewards.add(target, to: &rewards, now: now)
        saveRewards()
        if let added {
            store.log("WATCHLIST added \(added.name)")
        } else {
            store.log("WATCHLIST kept \(target) (asked to add it again)")
        }
        onRewardsChanged()
        return nil
    }

    @discardableResult
    func removeWatch(_ id: UUID, guardianApproved: Bool = false) -> Rewards.RemoveResult? {
        guard let item = rewards.watchlist.first(where: { $0.id == id }) else { return nil }
        let result = Rewards.remove(id, from: &rewards, guardian: guardianApproved, now: now)
        saveRewards()
        switch result {
        case .removed: store.log("WATCHLIST took off \(item.name)\(guardianApproved ? " (guardian)" : "")")
        case let .scheduled(at): store.log("WATCHLIST \(item.name) comes off at \(at.formatted(date: .abbreviated, time: .shortened))")
        case nil: break
        }
        onRewardsChanged()
        return result
    }

    func keepWatching(_ id: UUID) {
        guard let i = rewards.watchlist.firstIndex(where: { $0.id == id }) else { return }
        rewards.watchlist[i].removeAt = nil
        saveRewards()
        store.log("WATCHLIST keeping \(rewards.watchlist[i].name)")
    }

    // MARK: Research passes

    func latestPass(itemID: UUID) -> ResearchPass? { rewards.passes.last { $0.itemID == itemID } }

    func activePass(itemID: UUID) -> ResearchPass? { Rewards.activePass(for: itemID, state: rewards, now: now) }

    /// nil when the request went to Claude, otherwise why not.
    func askPass(itemID: UUID, taskID: UUID, reason: String) -> String? {
        guard let item = rewards.watchlist.first(where: { $0.id == itemID }) else { return RewardsRefusal.notWatched.message }
        guard let t = task(taskID), t.isPending else { return "Pick a task that's still due." }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 10 else { return "Say what you need it for." }
        if let refusal = Rewards.canAskPass(taskID: taskID, state: rewards, now: now) { return refusal.message }
        let pass = ResearchPass(itemID: itemID, itemName: item.name, taskID: taskID, taskTitle: t.title, reason: text, askedAt: now)
        let already = Rewards.minutesGranted(taskID: taskID, state: rewards)
        rewards.passes.append(pass)
        saveRewards()
        store.log("PASS asked for \(item.name) for \"\(t.title)\"")
        let folder = store.dir.appendingPathComponent("passes/\(pass.id.uuidString)", isDirectory: true)
        let settings = self.settings
        let tokenFile = self.tokenFile
        Task {
            let (decision, minutes, answer) = await ProofVerifier.decidePass(
                task: t, itemName: item.name, isSite: item.isSite, reason: text, minutesAlready: already,
                folder: folder, settings: settings, tokenFile: tokenFile)
            self.recordPass(pass.id, decision: decision, minutes: minutes, answer: answer)
        }
        return nil
    }

    private func recordPass(_ id: UUID, decision: PassDecision, minutes: Int, answer: String) {
        guard let i = rewards.passes.firstIndex(where: { $0.id == id }) else { return }
        let granted = decision == .granted ? min(max(minutes, 1), Rewards.maxPassMinutes) : 0
        rewards.passes[i].decision = granted > 0 ? .granted : (decision == .error ? .error : .denied)
        rewards.passes[i].minutes = granted
        rewards.passes[i].answer = answer
        rewards.passes[i].until = granted > 0 ? now.addingTimeInterval(TimeInterval(granted) * 60) : nil
        saveRewards()
        let p = rewards.passes[i]
        let word = granted > 0 ? "granted \(granted) min" : (decision == .error ? "couldn't be decided" : "denied")
        store.log("PASS \(word) for \(p.itemName) (\"\(p.taskTitle)\"): reason \"\(p.reason)\"; Claude: \(answer)")
        onRewardsChanged()
    }

    // MARK: Wishlist

    func addWish(name: String, realPrice: String, note: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = realPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "Give it a name." }
        guard !p.isEmpty else { return "Say what it costs." }
        let item = WishItem(name: n, realPrice: p, note: note.trimmingCharacters(in: .whitespacesAndNewlines), addedAt: now)
        rewards.wishes.append(item)
        saveRewards()
        store.log("WISHLIST added \"\(n)\" (\(p))")
        priceWish(item.id)
        return nil
    }

    /// A plain dollar price is worked out here at once; anything else goes to Claude to turn into dollars.
    /// Either way the credits are dollars ÷ the guardian's rate, so prices scale with what things cost.
    func priceWish(_ id: UUID) {
        guard let i = rewards.wishes.firstIndex(where: { $0.id == id }) else { return }
        let item = rewards.wishes[i]
        if let usd = Rewards.localUSD(item.realPrice) {
            setWishDollars(id, usd: usd, note: "")
            return
        }
        rewards.wishes[i].state = .pricing
        saveRewards()
        let folder = store.dir.appendingPathComponent("wishlist/\(id.uuidString)", isDirectory: true)
        let settings = self.settings
        let tokenFile = self.tokenFile
        Task {
            let result = await ProofVerifier.priceWish(name: item.name, realPrice: item.realPrice, note: item.note,
                                                       folder: folder, settings: settings, tokenFile: tokenFile)
            guard let j = self.rewards.wishes.firstIndex(where: { $0.id == id }), self.rewards.wishes[j].state == .pricing else { return }
            switch result {
            case let .success(price):
                self.setWishDollars(id, usd: price.usd, note: price.note)
                return
            case let .failure(problem):
                self.rewards.wishes[j].state = .unpriced(reason: problem.message)
                self.store.log("WISHLIST couldn't price \"\(item.name)\": \(problem.message)")
            }
            self.saveRewards()
        }
    }

    private func setWishDollars(_ id: UUID, usd: Double, note: String) {
        guard let i = rewards.wishes.firstIndex(where: { $0.id == id }) else { return }
        let rate = settings.dollarsPerCredit
        rewards.wishes[i].usd = usd
        rewards.wishes[i].credits = Rewards.wishCredits(usd: usd, dollarsPerCredit: rate)
        rewards.wishes[i].priceReason = Rewards.wishReason(usd: usd, dollarsPerCredit: rate,
                                                           weeklyEarning: Rewards.weeklyEarning(rewards, now: now), note: note)
        rewards.wishes[i].pricedBy = "the wishlist rate"
        rewards.wishes[i].state = .priced
        saveRewards()
        store.log("WISHLIST \"\(rewards.wishes[i].name)\" priced at \(Credits.format(rewards.wishes[i].credits ?? 0)): \(rewards.wishes[i].priceReason)")
    }

    /// Items priced by the old way (Claude guessing credits) are priced again by the rate.
    func repriceOldWishes() {
        for w in rewards.wishes where w.usd == nil && w.pricedBy == "Claude" && w.state == .priced {
            store.log("WISHLIST pricing \"\(w.name)\" again by the wishlist rate")
            priceWish(w.id)
        }
    }

    /// nil when bought, otherwise why not.
    func buyWish(_ id: UUID) -> String? {
        if let refusal = Rewards.buy(id, state: &rewards, locked: lock.isLocked, now: now) { return refusal.message }
        saveRewards()
        if let w = rewards.wishes.first(where: { $0.id == id }) {
            store.log("WISHLIST bought \"\(w.name)\" for \(Credits.format(w.credits ?? 0))")
        }
        return nil
    }

    /// Only before it's bought; it isn't something you can take back afterwards.
    func deleteWish(_ id: UUID) {
        guard let i = rewards.wishes.firstIndex(where: { $0.id == id }) else { return }
        switch rewards.wishes[i].state {
        case .bought: return
        default: break
        }
        store.log("WISHLIST removed \"\(rewards.wishes[i].name)\"")
        rewards.wishes.remove(at: i)
        saveRewards()
    }

    // MARK: Guardian

    func setWishPrice(_ id: UUID, credits: Double) {
        guard let i = rewards.wishes.firstIndex(where: { $0.id == id }), credits > 0 else { return }
        switch rewards.wishes[i].state {
        case .bought, .given: return
        default: break
        }
        rewards.wishes[i].credits = Credits.rounded(credits)
        rewards.wishes[i].pricedBy = Self.guardianName
        rewards.wishes[i].priceReason = "Set by your guardian."
        rewards.wishes[i].state = .priced
        saveRewards()
        store.log("GUARDIAN priced \"\(rewards.wishes[i].name)\" at \(Credits.format(credits))")
    }

    func settleWish(_ id: UUID, given: Bool) {
        Rewards.settle(id, given: given, state: &rewards, now: now)
        saveRewards()
        if let w = rewards.wishes.first(where: { $0.id == id }) {
            store.log("GUARDIAN \(given ? "gave" : "refunded") \"\(w.name)\"")
        }
    }

    func adjustCredits(_ amount: Double, note: String) {
        let a = Credits.rounded(amount)
        guard a != 0 else { return }
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        rewards.ledger.append(LedgerEntry(at: now, amount: a, kind: .guardian, note: text.isEmpty ? "From your guardian" : text))
        saveRewards()
        store.log("GUARDIAN \(a > 0 ? "added" : "took") \(Credits.format(abs(a)))\(text.isEmpty ? "" : ": \(text)")")
    }

    /// Changes the wishlist rate and reprices everything not yet bought (except prices the guardian set).
    func setDollarsPerCredit(_ rate: Double) {
        settings.dollarsPerCredit = min(max(rate, Rewards.dollarsPerCreditRange.lowerBound), Rewards.dollarsPerCreditRange.upperBound)
        store.saveSettings(settings)
        store.log("GUARDIAN set the wishlist rate to \(Rewards.dollars(settings.dollarsPerCredit)) a credit")
        for w in rewards.wishes where w.usd != nil && w.pricedBy != Self.guardianName && w.state == .priced {
            setWishDollars(w.id, usd: w.usd!, note: "")
        }
    }

    func setEarnRate(_ rate: Double) {
        settings.earnRate = min(max(rate, Credits.earnRateRange.lowerBound), Credits.earnRateRange.upperBound)
        store.saveSettings(settings)
        store.log("GUARDIAN set the earning rate to ×\(settings.earnRate)")
    }
}
