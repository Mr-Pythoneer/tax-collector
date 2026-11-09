import AppKit
import SwiftUI
import TaxCore

/// Your wallet, your watchlist and your wishlist.
struct RewardsView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    let askGuardian: () -> Void
    /// Opens the guardian code, then just the credits controls.
    var giveCredits: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case wallet = "Wallet"
        case watchlist = "Watchlist"
        case wishlist = "Wishlist"
        var id: String { rawValue }
    }

    @State private var tab: Tab

    init(dismiss: @escaping () -> Void, askGuardian: @escaping () -> Void, giveCredits: @escaping () -> Void = {},
         tab: Tab = .wallet) {
        self.dismiss = dismiss
        self.askGuardian = askGuardian
        self.giveCredits = giveCredits
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Rewards").font(.title2.bold())
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .wallet: WalletTab(giveCredits: giveCredits)
            case .watchlist: WatchlistTab(askGuardian: askGuardian)
            case .wishlist: WishlistTab()
            }
        }
        .frame(width: 580, height: 640)
    }
}

// MARK: Wallet

private struct WalletTab: View {
    @Environment(AppModel.self) private var model
    let giveCredits: () -> Void
    @State private var minutes = 30
    @State private var message: RewardsMessage?

    var body: some View {
        let locked = model.lock.isLocked
        let cost = Double(minutes) / 30
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Credits.format(model.balance))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                    Text("1 credit = 30 min. Earn more by finishing early and well; late work earns nothing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                HStack {
                    Text("A guardian can give or take credits with their code.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Give or Take Credits…", action: giveCredits)
                }
            }

            Section("Free time") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Time left: \(Credits.duration(model.freeTimeLeft))")
                            .font(.body.monospacedDigit().weight(.medium))
                        Text(model.isSignedIn
                             ? "Signed in. Your time counts down while you use the watchlist."
                             : "Signed out. Your time is saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isSignedIn {
                        Button("Sign Out") {
                            model.signOut()
                            message = nil
                        }
                    } else {
                        Button("Sign In") {
                            message = model.signIn().map { .error($0) }
                        }
                        .disabled(model.freeTimeLeft <= 0 || locked)
                    }
                }
                HStack {
                    Stepper(value: $minutes, in: 15...120, step: 15) {
                        Text("\(Credits.duration(TimeInterval(minutes) * 60)) for \(Credits.format(cost))")
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("Buy Time") {
                        if let why = model.buyTime(credits: cost) {
                            message = .error(why)
                        } else {
                            message = .info("Added \(Credits.duration(TimeInterval(minutes) * 60)). Sign in when you want to use it.")
                        }
                    }
                    .disabled(locked || model.balance + 0.0001 < cost)
                }
                if locked {
                    Label(RewardsRefusal.locked.message, systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if model.balance + 0.0001 < cost {
                    Text("You need \(Credits.format(cost - model.balance)) more for that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message { message.view }
            }

            Section("History") {
                if model.rewards.ledger.isEmpty {
                    Text("Nothing yet. Credits show up here when your proof is accepted.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rewards.ledger.reversed()) { LedgerRow(entry: $0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(entry.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(Fmt.dateTime.string(from: entry.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text((entry.amount >= 0 ? "+" : "−") + Credits.format(abs(entry.amount)))
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(entry.amount >= 0 ? Color.green : Color.orange)
        }
        .padding(.vertical, 1)
    }

    private var title: String {
        switch entry.kind {
        case .earned: "Earned"
        case .freeTime: "Free time"
        case .wish: "Bought"
        case .refund: "Refund"
        case .guardian: entry.amount >= 0 ? "From your guardian" : "Taken by your guardian"
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .earned: "checkmark.seal"
        case .freeTime: "clock"
        case .wish: "gift"
        case .refund: "arrow.uturn.backward"
        case .guardian: "person.badge.key"
        }
    }
}

// MARK: Watchlist

private struct WatchlistTab: View {
    @Environment(AppModel.self) private var model
    let askGuardian: () -> Void

    @State private var site = ""
    @State private var message: RewardsMessage?
    /// The item you just asked to take off, to say how that works.
    @State private var scheduled: UUID?

    var body: some View {
        Form {
            Section {
                if model.watchlist.isEmpty {
                    Text("Nothing on it. Add sites and apps that pull you away from homework. Opening one shows a checkpoint first.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.watchlist) { row($0) }
            } header: {
                Text("On your watchlist")
            } footer: {
                Text("Nothing gets closed. Opening something here shows a checkpoint: use your free time, buy some, or ask for a school pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Add") {
                HStack {
                    TextField("Website", text: $site, prompt: Text("Type a website, like youtube.com"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(addSite)
                    Button("Add Site", action: addSite)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Menu("Add App") {
                        let apps = RunningApp.all(excluding: model.selfBundleID)
                        if apps.isEmpty {
                            Text("No other apps are running")
                        }
                        ForEach(apps) { app in
                            Button(app.name) { message = model.addApp(id: app.id, name: app.name).map { .error($0) } }
                        }
                        Divider()
                        Button("Choose an App…", action: chooseApp)
                    }
                    .fixedSize()
                    Text("For Minecraft, start the game first, then pick it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                AccessibilityRow()
                if let message { message.view }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                WatchIcon(item: item, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    if let pass = model.activePass(itemID: item.id), let until = pass.until {
                        Text("School pass until \(Fmt.time.string(from: until))")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let removeAt = item.removeAt {
                        Text("Comes off at \(Fmt.dateTime.string(from: removeAt))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if item.removeAt != nil {
                    Button("Keep It") {
                        model.keepWatching(item.id)
                        if scheduled == item.id { scheduled = nil }
                    }
                    .controlSize(.small)
                } else {
                    Button("Remove") {
                        if case .scheduled = model.removeWatch(item.id) { scheduled = item.id }
                    }
                    .controlSize(.small)
                }
            }
            if scheduled == item.id && item.removeAt != nil {
                HStack {
                    Text("Comes off in 24 hours. The guardian can take it off now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Ask Your Guardian…", action: askGuardian)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func addSite() {
        let text = site.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            message = .error("Type a website in the box first, like youtube.com.")
            return
        }
        if let why = model.addSite(text) {
            message = .error(why)
        } else {
            message = nil
            site = ""
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        message = nil
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                message = .error("\(url.deletingPathExtension().lastPathComponent) can't be watched: it has no bundle ID. Start it and pick it from the running apps.")
                continue
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if let why = model.addApp(id: id, name: name) { message = .error(why) }
        }
    }
}

/// Firefox, Zen and Tor don't tell other apps their address, so watching them needs Accessibility.
private struct AccessibilityRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Reading the clock re-checks the permission every second, so the row goes away once it's given.
        let _ = model.now
        if !Checkpoint.isAccessibilityTrusted {
            HStack {
                Label("Firefox, Zen and Tor need Accessibility to be watched", systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow…") { Checkpoint.askForAccessibility() }
                    .controlSize(.small)
            }
        }
    }
}

/// A regular app that's running now, as the watchlist names it.
struct RunningApp: Identifiable, Hashable {
    let id: String
    let name: String

    @MainActor
    static func all(excluding selfID: String?) -> [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, app.bundleIdentifier == nil || app.bundleIdentifier != selfID else { return nil }
            let id = Rewards.appID(bundleID: app.bundleIdentifier,
                                   processName: app.executableURL?.lastPathComponent ?? app.localizedName ?? "")
            guard id != "proc:", seen.insert(id).inserted else { return nil }
            return RunningApp(id: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A globe for a site, the app's own icon for an app.
struct WatchIcon: View {
    let item: WatchItem
    var size: CGFloat = 20

    var body: some View {
        Group {
            switch item.target {
            case .site:
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.1)
            case let .app(id, _):
                if !id.hasPrefix("proc:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(size * 0.1)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Wishlist

private struct WishlistTab: View {
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var price = ""
    @State private var note = ""
    @State private var message: RewardsMessage?
    @State private var buyMessages: [UUID: String] = [:]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. wireless headphones"))
                    .textFieldStyle(.roundedBorder)
                TextField("Real price", text: $price, prompt: Text("e.g. $25"))
                    .textFieldStyle(.roundedBorder)
                TextField("Note", text: $note, prompt: Text("Optional: which one, where from"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if let message { message.view }
                    Spacer()
                    Button("Add to Wishlist", action: add)
                }
            } header: {
                Text("Add something you want")
            } footer: {
                Text("Its price in credits is what it costs ÷ \(Rewards.dollars(model.settings.dollarsPerCredit)) (the guardian sets that rate). Claude converts other currencies. A parent hands it over once you buy it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Your wishlist") {
                if model.rewards.wishes.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(model.rewards.wishes.reversed()) { row($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        if let why = model.addWish(name: name, realPrice: price, note: note) {
            message = .error(why)
        } else {
            message = nil
            name = ""
            price = ""
            note = ""
        }
    }

    private func row(_ wish: WishItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wish.name).fontWeight(.medium)
                    Text(wish.realPrice + (wish.note.isEmpty ? "" : " · \(wish.note)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let credits = wish.credits, !isPricing(wish) {
                    Text(Credits.format(credits))
                        .font(.callout.monospacedDigit().weight(.medium))
                }
            }
            state(wish)
            if let why = buyMessages[wish.id] {
                Text(why).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func state(_ wish: WishItem) -> some View {
        switch wish.state {
        case .pricing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Claude is pricing it…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                removeButton(wish)
            }
        case let .unpriced(reason):
            HStack {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { model.priceWish(wish.id) }.controlSize(.small)
                removeButton(wish)
            }
        case .priced:
            if !wish.priceReason.isEmpty {
                Text(wish.priceReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let short = shortBy(wish) {
                    Text("You need \(Credits.format(short)) more.").font(.caption).foregroundStyle(.secondary)
                } else if model.lock.isLocked {
                    Text(RewardsRefusal.locked.message).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                removeButton(wish)
                Button("Buy") {
                    buyMessages[wish.id] = model.buyWish(wish.id)
                }
                .controlSize(.small)
                .disabled(!wish.canBuy || shortBy(wish) != nil || model.lock.isLocked)
            }
        case let .bought(at):
            Label("Bought: show a parent", systemImage: "gift.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
                .help("Bought \(Fmt.dateTime.string(from: at)). Your guardian marks it given, or gives the credits back.")
        case let .given(at):
            HStack {
                Label("Given \(Fmt.dateTime.string(from: at))", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
                removeButton(wish)
            }
        case let .refunded(at):
            HStack {
                Label("Refunded \(Fmt.dateTime.string(from: at)). The credits are back in your wallet.",
                      systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                removeButton(wish)
            }
        }
    }

    private func removeButton(_ wish: WishItem) -> some View {
        Button("Remove") {
            buyMessages[wish.id] = nil
            model.deleteWish(wish.id)
        }
        .controlSize(.small)
    }

    private func isPricing(_ wish: WishItem) -> Bool {
        if case .pricing = wish.state { return true }
        return false
    }

    /// How many credits you're short, or nil when you have enough.
    private func shortBy(_ wish: WishItem) -> Double? {
        guard let price = wish.credits, model.balance + 0.0001 < price else { return nil }
        return price - model.balance
    }
}

// MARK: Shared

/// A line under a control: why something didn't work, or what just happened.
enum RewardsMessage: Equatable {
    case error(String)
    case info(String)

    @ViewBuilder
    var view: some View {
        switch self {
        case let .error(text):
            Text(text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case let .info(text):
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
