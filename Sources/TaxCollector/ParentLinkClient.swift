import AppKit
import CryptoKit
import TaxCore

/// Talks to the family's relay server: takes parents' commands, keeps their phones up to date, and pairs new
/// phones. docs/parent-link-v1.md is the protocol; this is the computer's side of it.
@MainActor
@Observable
final class ParentLinkClient {
    enum Status: Equatable {
        case off
        case connecting
        case online
        case offline(String)
    }

    enum Pairing: Equatable {
        case idle
        /// Showing the code for the parent to type into their phone.
        case waiting(code: String, expires: Date)
        /// Both screens should show `code`. The guardian code approves.
        case confirm(name: String, code: String)
        case finished(name: String)
        case failed(String)
    }

    private(set) var link: LinkFile?
    private(set) var status: Status = .off
    private(set) var pairing: Pairing = .idle

    @ObservationIgnored let store: Store
    @ObservationIgnored weak var model: AppModel?
    /// Testing aids (test copies only): a server to use, and approving pairings without the guardian code.
    @ObservationIgnored var serverOverride: String?
    @ObservationIgnored var autoConfirmPairing = false
    @ObservationIgnored var isTestCopy = false

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var instance: String?
    @ObservationIgnored private var needsResync = true
    @ObservationIgnored private var uploadSoon = true
    @ObservationIgnored private var lastHash: Data?
    @ObservationIgnored private var lastUpload = Date.distantPast
    @ObservationIgnored private var lastAliveNote = Date.distantPast
    @ObservationIgnored private var serverClock: (server: Int64, local: Date)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startupFlags: [WireState.Flag] = []

    private struct Failure: Error { let message: String }

    private var backupKey: String {
        "ParentLinkBackup-" + LinkCrypto.base64url(LinkCrypto.sha256(Data(store.dir.path.utf8))).prefix(12)
    }

    init(store: Store) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        link = store.loadLink()
    }

    var isConfigured: Bool { link != nil }
    var devices: [LinkedDevice] { link?.devices ?? [] }
    var serverURL: String { serverOverride ?? link?.serverURL ?? "" }

    // MARK: Starting and stopping

    /// Call once the model is set. Restores a deleted link file from its backup, notes tampering, and connects.
    func start() {
        guard let model else { return }
        if link == nil, model.settings.parentLinked,
           let data = UserDefaults.standard.data(forKey: backupKey),
           let restored = try? JSONDecoder().decode(LinkFile.self, from: data) {
            link = restored
            link?.notes["restoredAt"] = String(WireState.ms(model.now))
            store.saveLink(link)
            store.log("PARENT link file was missing; restored it from the backup copy")
        }
        guard link != nil else { status = .off; return }
        checkForTamperingSinceLastRun()
        connect()
    }

    private func connect() {
        loops.forEach { $0.cancel() }
        status = .connecting
        needsResync = true
        loops = [Task { await self.commandLoop() }, Task { await self.stateLoop() }]
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presence(awake: false) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.link != nil else { return }
                self.presence(awake: true)
                self.connect()
            }
        })
    }

    /// First-time setup from Guardian Settings. Returns nil when it worked, or what went wrong.
    func setUp(server raw: String, setupCode: String) async -> String? {
        var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while server.hasSuffix("/") { server.removeLast() }
        if !server.lowercased().hasPrefix("http") { server = "https://" + server }
        guard URL(string: server)?.host != nil else { return "That doesn't look like a web address." }
        let candidate = LinkFile(serverURL: server, setupCode: setupCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        let previous = link
        link = candidate
        do {
            let health = try await call("GET", "/v1/health")
            guard health.status == 200, health.body["ok"] as? Bool == true else {
                throw Failure(message: "There's no Tax Collector server at that address.")
            }
            try await ensureChannel()
        } catch {
            link = previous
            return (error as? Failure)?.message ?? "Couldn't reach the server: \(error.localizedDescription)"
        }
        save()
        store.log("PARENT link set up with \(URL(string: server)?.host ?? "the server")")
        connect()
        return nil
    }

    /// Unpairs every phone and forgets the server. Only from Guardian Settings.
    func unlink() async {
        if link != nil { _ = try? await call("DELETE", "/v1/channels/\(link!.channel)", token: link!.computerToken) }
        loops.forEach { $0.cancel() }
        loops = []
        link = nil
        store.saveLink(nil)
        UserDefaults.standard.removeObject(forKey: backupKey)
        model?.settings.parentLinked = false
        if let model { store.saveSettings(model.settings) }
        status = .off
        store.log("GUARDIAN unlinked all parents' phones")
    }

    /// A setting was changed on this computer, so an older change from a phone mustn't win over it.
    func noteLocal(_ setting: String) {
        guard link != nil, let model else { return }
        if setting == "guardian" {
            link?.notes["guardian"] = guardianFingerprint()
        } else {
            link?.settingTimes[setting] = WireState.ms(model.now)
        }
        save()
        uploadSoon = true
    }

    // MARK: Server calls

    private func call(_ method: String, _ path: String, json: Any? = nil, token: String? = nil,
                      timeout: TimeInterval = 40) async throws -> (status: Int, body: [String: Any]) {
        guard let url = URL(string: serverURL + path) else { throw Failure(message: "No server address.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "The server sent something odd.") }
        if let id = http.value(forHTTPHeaderField: "X-TC-Instance") {
            if let instance, instance != id { needsResync = true }
            instance = id
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let t = body["serverTime"] as? NSNumber { serverClock = (t.int64Value, Date()) }
        return (http.statusCode, body)
    }

    /// Makes sure the server has this computer's channel and phones, e.g. after it lost its data.
    private func ensureChannel() async throws {
        guard let link else { return }
        let made = try await call("PUT", "/v1/channels/\(link.channel)",
                                  json: ["setupCode": link.setupCode, "tokenHash": link.tokenHash], token: link.computerToken)
        switch made.status {
        case 200, 201: break
        case 403: throw Failure(message: "The setup code is wrong. It's printed when the server first starts.")
        case 409: throw Failure(message: "That server already has a different computer under this name.")
        case 429: throw Failure(message: "That server has no room for another computer.")
        default: throw Failure(message: "The server said no (\(made.status)).")
        }
        try await registerDevices()
    }

    private func registerDevices() async throws {
        guard let link else { return }
        let list = link.devices.map { ["id": $0.id, "tokenHash": $0.tokenHash] }
        let result = try await call("PUT", "/v1/ch/\(link.channel)/devices", json: ["devices": list], token: link.computerToken)
        guard result.status == 204 || result.status == 200 else { throw Failure(message: "Couldn't register the phones (\(result.status)).") }
    }

    private func presence(awake: Bool) {
        guard let link else { return }
        Task { _ = try? await self.call("POST", "/v1/ch/\(link.channel)/presence", json: ["awake": awake], token: link.computerToken, timeout: 5) }
    }

    // MARK: Commands

    private func commandLoop() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            guard let link else { return }
            do {
                if needsResync {
                    try await ensureChannel()
                    needsResync = false
                    uploadSoon = true
                }
                let result = try await call("GET", "/v1/ch/\(link.channel)/cmd?wait=25", token: link.computerToken)
                if result.status == 404 || result.status == 401 { needsResync = true; continue }
                guard result.status == 200 else { throw Failure(message: "The server answered \(result.status).") }
                status = .online
                backoff = 1
                let commands = result.body["commands"] as? [[String: Any]] ?? []
                var upTo: Int64 = 0
                for command in commands {
                    handle(command)
                    upTo = max(upTo, (command["seq"] as? NSNumber)?.int64Value ?? 0)
                }
                if upTo > 0 {
                    _ = try await call("POST", "/v1/ch/\(link.channel)/cmd/ack", json: ["upTo": upTo], token: link.computerToken)
                    // Answer right away, so a parent sees "Applied" in a second, not at the next check.
                    if await upload() {
                        lastUpload = model?.now ?? Date()
                        uploadSoon = false
                    } else {
                        uploadSoon = true
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                status = .offline((error as? Failure)?.message ?? error.localizedDescription)
                try? await Task.sleep(nanoseconds: UInt64((backoff + Double.random(in: 0...backoff / 2)) * 1e9))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func handle(_ raw: [String: Any]) {
        guard var link, let model else { return }
        let dev = raw["dev"] as? String ?? ""
        let receivedAt = (raw["receivedAt"] as? NSNumber)?.int64Value ?? 0
        let nowMs = WireState.ms(model.now)
        guard let device = link.devices.first(where: { $0.id == dev }), let key = device.key, let signKey = device.signKeyData,
              let box = (raw["box"] as? String).flatMap(LinkCrypto.fromBase64url) else {
            link.record(CommandResult(dev: dev, n: 0, id: "", type: "", outcome: "rejected", reason: "unknown_device", at: nowMs))
            self.link = link
            save()
            return
        }
        switch CommandGate.admit(box: box, linkKey: key, signKey: signKey, channel: link.channel, device: dev,
                                 receivedAt: receivedAt, lastCounter: link.lastCounter[dev] ?? 0) {
        case let .failure(rejection):
            let why = rejection.reason
            if why == .badBox || why == .badSignature {
                link.notes["badCommand"] = String(nowMs)
                store.log("PARENT a command for \(device.name) failed its check (\(why.rawValue))")
            }
            let c = rejection.command
            link.record(CommandResult(dev: dev, n: c?.counter ?? 0, id: c?.id ?? "", type: c?.type ?? "", outcome: "rejected",
                                      reason: why.rawValue, at: nowMs,
                                      last: why == .replayed ? link.lastCounter[dev] : nil))
        case let .success(command):
            link.lastCounter[dev] = command.counter
            var outcome = ("unsupported", "")
            if let action = command.action {
                if let setting = action.setting, let last = link.settingTimes[setting], last > command.issuedAt {
                    outcome = ("noop", "A newer change came first.")
                } else if case let .removeDevice(id) = action {
                    self.link = link
                    outcome = removeDevice(id, by: device.name)
                    link = self.link ?? link
                } else {
                    self.link = link
                    outcome = model.applyParent(action, by: device.name)
                    link = self.link ?? link
                    if let setting = action.setting, outcome.0 != "rejected" { link.settingTimes[setting] = command.issuedAt }
                }
            }
            link.record(CommandResult(dev: dev, n: command.counter, id: command.id, type: command.type, outcome: outcome.0,
                                      reason: outcome.1, at: nowMs))
        }
        self.link = link
        save()
    }

    /// Unpairs one phone: its key and state copy go, and the server forgets its token.
    @discardableResult
    func removeDevice(_ id: String, by: String) -> (String, String) {
        guard var link, let device = link.devices.first(where: { $0.id == id }) else { return ("noop", "No such phone.") }
        link.devices.removeAll { $0.id == id }
        link.lastCounter[id] = nil
        self.link = link
        save()
        store.log("\(by == AppModel.guardianName ? "GUARDIAN" : "PARENT \(by)") removed the phone \(device.name)")
        Task { try? await self.registerDevices(); self.uploadSoon = true }
        return ("applied", "")
    }

    // MARK: State

    private func stateLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let link, !link.devices.isEmpty, let model else { continue }
            // Note what this running app set itself, so edits made while it wasn't running stand out next time.
            notePresentRules()
            if model.now.timeIntervalSince(lastAliveNote) >= 60 {
                self.link?.notes["alive"] = String(WireState.ms(model.now))
                lastAliveNote = model.now
                save()
            }
            let draft = buildState(seq: 0, sentAt: 0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let hash = (try? encoder.encode(draft)).map(LinkCrypto.sha256)
            guard uploadSoon || hash != lastHash || model.now.timeIntervalSince(lastUpload) > 600 else { continue }
            if await upload() {
                lastHash = hash
                lastUpload = model.now
                uploadSoon = false
            }
        }
    }

    private func buildState(seq: Int64, sentAt: Int64) -> WireState {
        guard let model, let link else { return StateBuilder.build(.init(seq: 0, now: Date(), computer: computerInfo(), tasks: [], recurring: [], settings: Settings(), lock: LockState(), checking: [], builtIn: [], running: [], recent: [], activity: [], results: [], devices: [], flags: [], accessBy: "", accessAt: 0)) }
        var state = StateBuilder.build(model.stateInput(
            seq: seq, computer: computerInfo(), results: link.results,
            devices: link.devices.map { WireState.Device(id: $0.id, name: $0.name, pairedAt: $0.pairedAt) },
            flags: flags(), accessAt: link.settingTimes["access"] ?? 0))
        state.sentAt = sentAt
        return state
    }

    private func upload() async -> Bool {
        guard var link, let model else { return false }
        link.stateSeq += 1
        self.link = link
        save()
        let state = buildState(seq: link.stateSeq, sentAt: WireState.ms(model.now))
        guard let packed = StateBuilder.encode(state) else { return false }
        var copies: [String: String] = [:]
        for device in link.devices {
            guard let key = device.key,
                  let box = try? LinkCrypto.seal(packed, key: key, aad: LinkCrypto.stateAAD(channel: link.channel, device: device.id))
            else { continue }
            copies[device.id] = LinkCrypto.base64url(box)
        }
        do {
            let result = try await call("PUT", "/v1/ch/\(link.channel)/state", json: ["seq": link.stateSeq, "copies": copies],
                                        token: link.computerToken)
            if result.status == 404 { needsResync = true }
            return result.status == 204 || result.status == 200
        } catch {
            return false
        }
    }

    private func computerInfo() -> WireState.Computer {
        WireState.Computer(name: Host.current().localizedName ?? "Mac", platform: "mac",
                           app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                           os: ProcessInfo.processInfo.operatingSystemVersionString, timeZone: TimeZone.current.identifier)
    }

    // MARK: Tamper and health flags (docs/parent-link-v1.md §8)

    private func guardianFingerprint() -> String {
        let data = (try? Data(contentsOf: store.dir.appendingPathComponent("guardian.json"))) ?? Data()
        return LinkCrypto.base64url(LinkCrypto.sha256(data))
    }

    private func rulesFingerprint() -> String {
        guard let s = model?.settings else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Rules: Encodable {
            var overrideUntil: Date?
            var parentLock: ParentLock?
            var blocked: [AppRef]
            var allowed: [String]
            var penalty: Int
            var extensions: Bool
        }
        let rules = Rules(overrideUntil: s.overrideUntil, parentLock: s.parentLock, blocked: s.blockedApps,
                          allowed: s.extraAllowedBundleIDs, penalty: s.penaltyMinutes, extensions: s.extensionsEnabled)
        return LinkCrypto.base64url(LinkCrypto.sha256((try? encoder.encode(rules)) ?? Data()))
    }

    private func notePresentRules() {
        let rules = rulesFingerprint(), guardian = guardianFingerprint()
        if link?.notes["rules"] != rules || link?.notes["guardian"] != guardian {
            link?.notes["rules"] = rules
            link?.notes["guardian"] = guardian
            save()
        }
    }

    /// Compares what was on disk when the app last ran with what's there now, and checks for time it wasn't running.
    private func checkForTamperingSinceLastRun() {
        guard let link, let model else { return }
        let nowMs = WireState.ms(model.now)
        var flags: [WireState.Flag] = []
        if let saved = link.notes["guardian"], saved != guardianFingerprint() {
            flags.append(.init(kind: "guardianChanged", text: "The guardian code was changed or removed while Tax Collector wasn't running.", at: nowMs))
        }
        if let saved = link.notes["rules"], saved != rulesFingerprint() {
            flags.append(.init(kind: "overrideMismatch", text: "Lock, unlock or app settings were edited while Tax Collector wasn't running.", at: nowMs))
        }
        if let alive = link.notes["alive"].flatMap(Int64.init) {
            let aliveDate = Date(timeIntervalSince1970: Double(alive) / 1000)
            let boot = Self.sysctlTime("kern.boottime") ?? .distantPast
            let wake = Self.sysctlTime("kern.waketime") ?? .distantPast
            if model.now.timeIntervalSince(aliveDate) > 5 * 60, boot < aliveDate, wake < aliveDate {
                flags.append(.init(kind: "gap", text: "Tax Collector wasn't running from \(Fmt.dateTime.string(from: aliveDate)) to \(Fmt.time.string(from: model.now)), while this Mac was on.", at: nowMs))
            }
        }
        startupFlags = flags
        for flag in flags { store.log("PARENT warning: \(flag.text)") }
    }

    private func flags() -> [WireState.Flag] {
        guard let model, let link else { return [] }
        let nowMs = WireState.ms(model.now)
        var out = startupFlags.filter { nowMs - $0.at < 24 * 3600 * 1000 }
        if model.dryRun || model.enforcer.onlyTargets != nil || isTestCopy {
            out.append(.init(kind: "testMode", text: "Tax Collector is in test mode, so it isn't really closing apps.", at: nowMs))
        }
        if !isTestCopy && !FileManager.default.fileExists(atPath: BackgroundAgent.plistURL.path) {
            out.append(.init(kind: "noBackgroundAgent", text: "Tax Collector isn't set to run in the background, so nothing restarts it if it's quit.", at: nowMs))
        }
        if let clock = serverClock {
            let skew = Double(WireState.ms(clock.local) - clock.server) / 1000
            if abs(skew) > 120 {
                out.append(.init(kind: "clockSkew", text: "This Mac's clock is \(Int(abs(skew) / 60)) minutes \(skew > 0 ? "fast" : "slow").", at: nowMs))
            }
        }
        if let restored = link.notes["restoredAt"].flatMap(Int64.init), nowMs - restored < 24 * 3600 * 1000 {
            out.append(.init(kind: "linkRestored", text: "The link file was deleted, and Tax Collector restored it.", at: restored))
        }
        if let bad = link.notes["badCommand"].flatMap(Int64.init), nowMs - bad < 24 * 3600 * 1000 {
            out.append(.init(kind: "badCommand", text: "A command arrived that failed its signature check.", at: bad))
        }
        let today = Fmt.formatted(model.now, "yyyy-MM-dd")
        let starts = store.recentLog(lines: 400).filter { $0.hasPrefix(today) && $0.contains("  START") }.count
        if starts >= 3 {
            out.append(.init(kind: "restarts", text: "Tax Collector started \(starts) times today.", at: nowMs))
        }
        return out
    }

    private static func sysctlTime(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    // MARK: Pairing (docs/parent-link-v1.md §4)

    func startPairing() {
        guard link != nil else {
            pairing = .failed("Set up the server first.")
            return
        }
        pairingTask?.cancel()
        let code = LinkCrypto.newPairingCode()
        pairing = .waiting(code: code, expires: Date().addingTimeInterval(600))
        pairingTask = Task { await self.runPairing(code: code) }
    }

    func cancelPairing() {
        approval?.resume(returning: false)
        approval = nil
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    /// The parent compared the codes and typed the guardian code. nil means approved.
    func approvePairing(guardianCode: String) -> String? {
        guard let model else { return "Not ready." }
        switch model.checkGuardian(guardianCode) {
        case .ok:
            approval?.resume(returning: true)
            approval = nil
            return nil
        case .wrong: return "Wrong code."
        case let .coolingDown(until): return "Too many wrong codes. Try again at \(Fmt.time.string(from: until))."
        }
    }

    private func runPairing(code: String) async {
        guard let link, let computerKey = link.privateKey, let model else { return }
        let (slot, key) = LinkCrypto.pairing(code: code)
        let aad = LinkCrypto.pairAAD(slot: slot)
        let deadline = Date().addingTimeInterval(600)
        func seal(_ json: [String: Any]) throws -> String {
            LinkCrypto.base64url(try LinkCrypto.seal(try JSONSerialization.data(withJSONObject: json), key: key, aad: aad))
        }
        func messages(after: inout Int) async throws -> [[String: Any]] {
            let r = try await call("GET", "/v1/pair/\(slot)/toComputer?after=\(after)&wait=20", token: link.computerToken, timeout: 30)
            guard r.status == 200 else { throw Failure(message: "The server lost the pairing (\(r.status)).") }
            var out: [[String: Any]] = []
            for m in r.body["messages"] as? [[String: Any]] ?? [] {
                after = max(after, (m["n"] as? NSNumber)?.intValue ?? after)
                guard let box = (m["box"] as? String).flatMap(LinkCrypto.fromBase64url),
                      let plain = try? LinkCrypto.open(box, key: key, aad: aad),
                      let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { continue }
                out.append(json)
            }
            return out
        }
        func fail(_ text: String) async {
            if let box = try? seal(["t": "rejected", "why": text]) {
                _ = try? await call("POST", "/v1/pair/\(slot)/toPhone", json: ["box": box], token: link.computerToken)
            }
            _ = try? await call("DELETE", "/v1/pair/\(slot)", token: link.computerToken)
            pairing = .failed(text)
        }

        do {
            let hello: [String: Any] = ["t": "hello", "v": 1, "ch": link.channel, "name": computerInfo().name, "platform": "mac",
                                        "dhKey": LinkCrypto.base64url(computerKey.publicKey.x963Representation)]
            let made = try await call("PUT", "/v1/pair/\(slot)", json: ["ch": link.channel, "hello": try seal(hello)], token: link.computerToken)
            guard made.status == 201 || made.status == 200 else { throw Failure(message: "The server wouldn't start pairing (\(made.status)).") }

            // 1. The phone commits.
            var after = 0
            var commit: Data?
            while commit == nil {
                guard Date() < deadline, !Task.isCancelled else { return await fail("The code ran out. Start again.") }
                for m in try await messages(after: &after) where m["t"] as? String == "commit" {
                    if commit != nil { return await fail("Two phones tried to pair at once. Start again.") }
                    commit = (m["commit"] as? String).flatMap(LinkCrypto.fromBase64url)
                }
            }
            // 2. Then, and only then, this computer's nonce.
            let computerNonce = LinkCrypto.randomBytes(32)
            _ = try await call("POST", "/v1/pair/\(slot)/toPhone", json: ["box": try seal(["t": "nonce", "nonce": LinkCrypto.base64url(computerNonce)])],
                               token: link.computerToken)
            // 3. The phone reveals; it must match what it committed to.
            var reveal: [String: Any]?
            while reveal == nil {
                guard Date() < deadline, !Task.isCancelled else { return await fail("The code ran out. Start again.") }
                for m in try await messages(after: &after) {
                    if m["t"] as? String == "commit" { return await fail("Two phones tried to pair at once. Start again.") }
                    if m["t"] as? String == "reveal" { reveal = m }
                }
            }
            guard let r = reveal, let signKey = (r["signKey"] as? String).flatMap(LinkCrypto.fromBase64url),
                  let dhKey = (r["dhKey"] as? String).flatMap(LinkCrypto.fromBase64url),
                  let phoneNonce = (r["nonce"] as? String).flatMap(LinkCrypto.fromBase64url),
                  let tokenHash = (r["tokenHash"] as? String).flatMap(LinkCrypto.fromBase64url),
                  let rawName = r["name"] as? String, signKey.count == 65, dhKey.count == 65, phoneNonce.count == 32,
                  tokenHash.count == 32,
                  LinkCrypto.commitment(signKey: signKey, dhKey: dhKey, nonce: phoneNonce, tokenHash: tokenHash, name: rawName) == commit
            else { return await fail("The phone's answer didn't match. Start again.") }
            let name = WireState.clean(rawName, max: 40).trimmingCharacters(in: .whitespaces)
            let shown = LinkCrypto.comparisonCode(computerNonce: computerNonce, phoneNonce: phoneNonce,
                                                  computerDhKey: computerKey.publicKey.x963Representation,
                                                  phoneSignKey: signKey, phoneDhKey: dhKey)
            // 4. The parent compares the codes and types the guardian code.
            pairing = .confirm(name: name.isEmpty ? "A phone" : name, code: shown)
            let approved = autoConfirmPairing && isTestCopy ? true : await withCheckedContinuation { approval = $0 }
            guard approved else { return await fail("Pairing was turned down on the computer.") }

            let deviceID = UUID().uuidString.lowercased()
            let linkKey = try LinkCrypto.linkKey(computer: computerKey, phoneDhKey: dhKey, channel: link.channel, deviceID: deviceID)
            let device = LinkedDevice(id: deviceID, name: name.isEmpty ? "A phone" : name, signKey: LinkCrypto.base64url(signKey),
                                      dhKey: LinkCrypto.base64url(dhKey), tokenHash: LinkCrypto.base64url(tokenHash),
                                      linkKey: linkKey.withUnsafeBytes { LinkCrypto.base64url(Data($0)) },
                                      pairedAt: WireState.ms(model.now))
            self.link?.devices.append(device)
            save()
            try await registerDevices()
            _ = try await call("POST", "/v1/pair/\(slot)/toPhone", json: ["box": try seal(["t": "done", "dev": deviceID])], token: link.computerToken)
            _ = try? await call("DELETE", "/v1/pair/\(slot)", token: link.computerToken)
            model.settings.parentLinked = true
            store.saveSettings(model.settings)
            store.log("GUARDIAN paired the phone \(device.name)")
            pairing = .finished(name: device.name)
            uploadSoon = true
        } catch is CancellationError {
            _ = try? await call("DELETE", "/v1/pair/\(slot)", token: link.computerToken)
        } catch {
            await fail((error as? Failure)?.message ?? "Couldn't reach the server: \(error.localizedDescription)")
        }
    }

    // MARK: Saving

    private func save() {
        store.saveLink(link)
        if let link, let data = try? JSONEncoder().encode(link) { UserDefaults.standard.set(data, forKey: backupKey) }
    }
}
