import Foundation

public enum Allowlist {
    public struct App: Sendable {
        public let name: String
        public let bundleID: String
    }

    /// The apps you asked to keep during a lock.
    public static let apps: [App] = [
        App(name: "Arc", bundleID: "company.thebrowser.Browser"),
        App(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        App(name: "Microsoft Word", bundleID: "com.microsoft.Word"),
        App(name: "Microsoft Excel", bundleID: "com.microsoft.Excel"),
        App(name: "Microsoft PowerPoint", bundleID: "com.microsoft.Powerpoint"),
        App(name: "Microsoft Outlook", bundleID: "com.microsoft.Outlook"),
        App(name: "Microsoft OneNote", bundleID: "com.microsoft.onenote.mac"),
        App(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        App(name: "OneDrive", bundleID: "com.microsoft.OneDrive"),
        App(name: "Mail", bundleID: "com.apple.mail"),
        App(name: "Zoom", bundleID: "us.zoom.xos"),
        App(name: "VooV Meeting", bundleID: "com.tencent.tencentmeeting"),
        App(name: "Activity Monitor", bundleID: "com.apple.ActivityMonitor"),
    ]

    /// Every web browser. Some of a school's sites only work in one browser and some only after trying another,
    /// so during a lock all of them stay open. (Arc is in the list above.) A helper whose ID starts with one of these
    /// is covered too, which is how Chrome's Beta and Canary and Edge's Beta are allowed. A parent's blocked app
    /// still beats this list, so a phone can shut one browser out.
    /// Not every browser is installed here, so the IDs of the ones that aren't come from each vendor's own app.
    public static let browsers: [App] = [
        App(name: "Safari", bundleID: "com.apple.Safari"),
        App(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview"),
        App(name: "Google Chrome", bundleID: "com.google.Chrome"),
        App(name: "Google Chrome for Testing", bundleID: "com.google.chrome.for.testing"),
        App(name: "Chromium", bundleID: "org.chromium.Chromium"),
        App(name: "Firefox", bundleID: "org.mozilla.firefox"),
        App(name: "Firefox Developer Edition", bundleID: "org.mozilla.firefoxdeveloperedition"),
        App(name: "Firefox Nightly", bundleID: "org.mozilla.nightly"),
        App(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        App(name: "Brave", bundleID: "com.brave.Browser"),
        App(name: "Opera", bundleID: "com.operasoftware.Opera"),
        App(name: "Opera GX", bundleID: "com.operasoftware.OperaGX"),
        App(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
        App(name: "Orion", bundleID: "com.kagi.kagimacOS"),
        App(name: "DuckDuckGo", bundleID: "com.duckduckgo.macos.browser"),
        App(name: "Tor Browser", bundleID: "org.torproject.torbrowser"),
        App(name: "Zen", bundleID: "app.zen-browser.zen"),
        App(name: "Dia", bundleID: "company.thebrowser.dia"),
        App(name: "Comet", bundleID: "ai.perplexity.comet"),
        App(name: "ChatGPT Atlas", bundleID: "com.openai.atlas"),
        App(name: "SigmaOS", bundleID: "com.sigmaos.sigmaos.macos"),
        App(name: "Waterfox", bundleID: "net.waterfox.waterfox"),
        App(name: "LibreWolf", bundleID: "io.gitlab.librewolf-community"),
        App(name: "Yandex Browser", bundleID: "ru.yandex.desktop.yandex-browser"),
    ]

    /// Things the Mac (or the allowed apps) need to keep working. Not shown in the list.
    public static let implicit: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter",
        "com.apple.ScreenSaver.Engine",
        "com.microsoft.autoupdate2",
        "com.microsoft.autoupdate.fba",
        "com.microsoft.errorreporting",
        "com.anthropic.claude-code-url-handler",
    ]

    /// The one rule for closing an app. The system and Tax Collector itself are never closed. A blocked app is
    /// closed whenever it runs. During a lock, everything not allowed is closed, and with a parent's
    /// "everything" lock, the allowed apps too.
    public static func shouldClose(bundleID: String?, locked: Bool, strength: LockStrength, extra: [String],
                                   blocked: [String], selfID: String?) -> Bool {
        if let id = bundleID {
            if let selfID, id == selfID { return false }
            if implicit.contains(id) { return false }
            if blocked.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
        }
        guard locked else { return false }
        if strength == .all { return true }
        return !isAllowed(bundleID: bundleID, extra: extra, selfID: selfID)
    }

    /// Exact match, or a helper whose ID starts with an allowed ID (e.g. `us.zoom.xos.Helper`).
    public static func isAllowed(bundleID: String?, extra: [String], selfID: String?) -> Bool {
        guard let id = bundleID else { return false }
        if let selfID, id == selfID { return true }
        if implicit.contains(id) { return true }
        let allowed = apps.map(\.bundleID) + browsers.map(\.bundleID) + extra
        return allowed.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}
