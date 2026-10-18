import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TaxCore

/// Guardian Settings: the family's server, the paired phones, and pairing a new one.
struct ParentsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ParentLinkClient.self) private var link
    @State private var server = ""
    @State private var setupCode = ""
    @State private var working = false
    @State private var message = ""
    @State private var showPairing = false
    @State private var confirmUnlink = false

    var body: some View {
        Section {
            if link.isConfigured {
                LabeledContent("Server") {
                    HStack(spacing: 6) {
                        statusDot
                        Text(URL(string: link.serverURL)?.host ?? link.serverURL).textSelection(.enabled)
                    }
                }
                if link.devices.isEmpty {
                    Text("No phones paired yet.").foregroundStyle(.secondary)
                }
                ForEach(link.devices) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                            Text("Paired \(Fmt.dateTime.string(from: Date(timeIntervalSince1970: Double(device.pairedAt) / 1000)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { link.removeDevice(device.id, by: AppModel.guardianName) }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Button("Pair a Phone…") {
                        link.startPairing()
                        showPairing = true
                    }
                    Spacer()
                    Button("Unlink All…", role: .destructive) { confirmUnlink = true }
                        .controlSize(.small)
                }
            } else {
                Text("Parents can follow homework and lock, unlock or manage this Mac from their phones, through a small server you run at home.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Server address", text: $server, prompt: Text("https://your-server.example.ts.net"))
                TextField("Setup code", text: $setupCode, prompt: Text("Printed when the server first starts"))
                HStack {
                    Button(working ? "Connecting…" : "Connect") {
                        working = true
                        message = ""
                        Task {
                            message = await link.setUp(server: server, setupCode: setupCode) ?? ""
                            working = false
                        }
                    }
                    .disabled(working || server.isEmpty || setupCode.isEmpty)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
        } header: {
            Text("Parents' phones")
        } footer: {
            if link.isConfigured {
                Text("Phones see tasks, proof results, what's blocked and recent activity, never your files, passwords or the guardian code. Anything a phone does shows up here as a notification.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPairing) { PairingSheet(close: { showPairing = false }) }
        .confirmationDialog("Unlink every parent's phone?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) { Task { await link.unlink() } }
        } message: {
            Text("The phones stop working with this Mac, and the server forgets it.")
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch link.status {
        case .online: Circle().fill(.green).frame(width: 7, height: 7).help("Connected")
        case .connecting: Circle().fill(.orange).frame(width: 7, height: 7).help("Connecting")
        case let .offline(why): Circle().fill(.red).frame(width: 7, height: 7).help(why)
        case .off: Circle().fill(.secondary).frame(width: 7, height: 7)
        }
    }
}

/// Showing the code, then comparing the 6 digits on both screens before the guardian code approves.
struct PairingSheet: View {
    @Environment(ParentLinkClient.self) private var link
    let close: () -> Void
    @State private var guardianCode = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a Parent's Phone").font(.title2.bold())
            switch link.pairing {
            case .idle:
                ProgressView()
            case let .waiting(code, expires):
                waiting(code: code, expires: expires)
            case let .confirm(name, code):
                confirm(name: name, code: code)
            case let .finished(name):
                Label("\(name) is paired.", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("It can see this Mac now. Pair the other parent's phone too, so either of you can remove a lost one.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { link.cancelPairing(); close() }.keyboardShortcut(.defaultAction) }
            case let .failed(why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { link.cancelPairing(); close() }
                    Button("Start Again") { link.startPairing() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func waiting(code: String, expires: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the parent's phone:").font(.headline)
                    Text("1. Open \(URL(string: link.serverURL)?.host ?? link.serverURL) in Safari (Chrome on Android).")
                    Text("2. On iPhone, tap Share, then Add to Home Screen, and open it from the Home Screen.")
                    Text("3. Tap Pair a Computer and type this code:")
                    Text(LinkCrypto.displayCode(code))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let qr = QRCode.image(for: "\(link.serverURL)/#code=\(LinkCrypto.normaliseCode(code))") {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        .help("For Android or a computer. On iPhone, type the code in the Home Screen app instead.")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(expires.timeIntervalSince(context.date)))
                Text("Waiting for the phone… the code works for \(left / 60):\(String(format: "%02d", left % 60)) more.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel") { link.cancelPairing(); close() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func confirm(name: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Does \(name) show this number?").font(.headline)
            Text(String(code.prefix(3)) + " " + String(code.suffix(3)))
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
            Text("If it's different, someone else's phone is trying to pair. Turn it down and start again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Guardian code", text: $guardianCode).onSubmit(approve)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("It's Different") { link.cancelPairing(); close() }
                Spacer()
                Button("It Matches: Pair", action: approve).keyboardShortcut(.defaultAction).disabled(guardianCode.isEmpty)
            }
        }
    }

    private func approve() {
        error = link.approvePairing(guardianCode: guardianCode) ?? ""
        guardianCode = ""
    }
}

/// Guardian Settings: apps closed whenever they run.
struct BlockedAppsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.settings.blockedApps.isEmpty {
                Text("None. Blocked apps are closed whenever they open, locked or not.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.settings.blockedApps, id: \.id) { app in
                HStack {
                    Text(app.name)
                    Text(app.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unblock") { model.unblockApp(app.id, by: AppModel.guardianName) }.controlSize(.small)
                }
            }
            HStack {
                Menu("Block a Running App") {
                    ForEach(model.runningApps(), id: \.id) { app in
                        Button(app.name) { model.blockApp(app, by: AppModel.guardianName) }
                    }
                }
                .fixedSize()
                Button("Choose an App…", action: choose).controlSize(.small)
            }
        } header: {
            Text("Blocked apps")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            model.blockApp(AppRef(id: id, name: name), by: AppModel.guardianName)
        }
    }
}

enum QRCode {
    /// A crisp QR code for `text`, or nil.
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
