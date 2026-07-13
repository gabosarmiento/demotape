import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices
import UserNotifications

/// "About DemoTape" panel: version + metadata, a live view of which macOS permissions have
/// been granted (with a shortcut into the right System Settings pane for each), and a manual
/// "Check for Updates" button.
///
/// Privacy note: DemoTape makes no background network calls. The only network access here is
/// the update check, and it fires *only* when the user clicks "Check for Updates" — it queries
/// the public GitHub Releases API for this repo and compares the tag to the running version.
@available(macOS 12.3, *)
final class AboutController: NSObject, NSWindowDelegate {

    /// GitHub repo used for the manual update check.
    private static let repo = "gabosarmiento/demotape"

    private var window: NSWindow?
    private var permissionRows: [PermissionRow] = []
    private var updateStatus: NSTextField!
    private var updateButton: NSButton!
    private var openReleaseButton: NSButton!
    private var latestReleaseURL: URL?

    // MARK: - Permission model

    private enum Status { case granted, denied, notDetermined, unknown }

    private struct Permission {
        let name: String
        let detail: String
        let settingsURL: String
        let status: () -> Status
        /// Triggers the native permission request (which also registers the app in System
        /// Settings so it appears in the list). Calls back on the main queue when settled.
        let request: (@escaping () -> Void) -> Void
        /// True for permissions whose status API can't distinguish "never asked" from "denied"
        /// (Screen Recording, Accessibility). For these we track whether we've asked ourselves.
        let ambiguousDenied: Bool
    }

    /// A rendered row (label + status text + action button) we can refresh in place.
    private struct PermissionRow {
        let statusLabel: NSTextField
        let actionButton: NSButton
        let permission: Permission
    }

    private func permissions() -> [Permission] {
        [
            Permission(
                name: "Screen Recording",
                detail: "Required — capture the screen.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                status: { CGPreflightScreenCaptureAccess() ? .granted : .denied },
                request: { done in
                    // Prompts on first ask AND registers the app in the Screen Recording list.
                    _ = CGRequestScreenCaptureAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
                },
                ambiguousDenied: true),
            Permission(
                name: "Microphone",
                detail: "Optional — record narration.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                status: { Self.map(AVCaptureDevice.authorizationStatus(for: .audio)) },
                request: { done in
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { done() }
                    }
                },
                ambiguousDenied: false),
            Permission(
                name: "Camera",
                detail: "Optional — webcam overlay.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
                status: { Self.map(AVCaptureDevice.authorizationStatus(for: .video)) },
                request: { done in
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        DispatchQueue.main.async { done() }
                    }
                },
                ambiguousDenied: false),
            Permission(
                name: "Accessibility",
                detail: "Optional — keyboard-shortcut badges.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                status: { AXIsProcessTrusted() ? .granted : .denied },
                request: { done in
                    // Shows the "open Accessibility settings" prompt and registers the app.
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done() }
                },
                ambiguousDenied: true),
            Permission(
                name: "Notifications",
                detail: "Optional — \"render ready\" alerts.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.notifications",
                status: { .unknown },   // resolved asynchronously; see refreshNotificationStatus()
                request: { done in
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                        DispatchQueue.main.async { done() }
                    }
                },
                ambiguousDenied: false)
        ]
    }

    // Track whether we've fired a request for an "ambiguous" permission, so we can tell
    // "never asked" (show Request Access) from a real denial (show Open Settings).
    private func hasRequested(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: "about.requested.\(name)")
    }
    private func markRequested(_ name: String) {
        UserDefaults.standard.set(true, forKey: "about.requested.\(name)")
    }

    /// The status to display, resolving the ambiguous never-asked-vs-denied case.
    private func effectiveStatus(for perm: Permission) -> Status {
        let raw = perm.status()
        if perm.ambiguousDenied, case .denied = raw, !hasRequested(perm.name) {
            return .notDetermined
        }
        return raw
    }

    private static func map(_ s: AVAuthorizationStatus) -> Status {
        switch s {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func text(for status: Status) -> (String, NSColor) {
        switch status {
        case .granted: return ("● Granted", .systemGreen)
        case .denied: return ("● Not granted", .systemRed)
        case .notDetermined: return ("○ Not requested yet", .systemOrange)
        case .unknown: return ("○ Checking…", .secondaryLabelColor)
        }
    }

    // MARK: - Window

    func show() {
        if let window = window {
            refreshStatuses()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w: CGFloat = 460, h: CGFloat = 560
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "About DemoTape"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let leftX: CGFloat = 24

        // --- Header: icon + name + version ---
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let icon = NSImage(contentsOf: url) {
            let iv = NSImageView(frame: NSRect(x: leftX, y: h - 96, width: 72, height: 72))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(iv)
        }

        let name = NSTextField(labelWithString: "DemoTape")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        name.frame = NSRect(x: leftX + 88, y: h - 52, width: w - leftX - 88 - 24, height: 28)
        content.addSubview(name)

        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let ver = NSTextField(labelWithString: "Version \(short) (build \(build))")
        ver.font = .systemFont(ofSize: 12)
        ver.textColor = .secondaryLabelColor
        ver.frame = NSRect(x: leftX + 88, y: h - 74, width: w - leftX - 88 - 24, height: 18)
        content.addSubview(ver)

        let tagline = NSTextField(labelWithString: "Local-first screen recorder for macOS")
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = .secondaryLabelColor
        tagline.frame = NSRect(x: leftX + 88, y: h - 94, width: w - leftX - 88 - 24, height: 16)
        content.addSubview(tagline)

        // --- Metadata ---
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.demotape.app"
        let minOS = Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String ?? "12.3"
        let meta = NSTextField(wrappingLabelWithString:
            "Identifier: \(bundleID)\nRequires macOS \(minOS)+   ·   MIT License")
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.frame = NSRect(x: leftX, y: h - 140, width: w - 48, height: 34)
        content.addSubview(meta)

        // --- Permissions section ---
        let permHeader = NSTextField(labelWithString: "Permissions")
        permHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        permHeader.frame = NSRect(x: leftX, y: h - 172, width: w - 48, height: 18)
        content.addSubview(permHeader)

        var y: CGFloat = h - 200
        permissionRows.removeAll()
        for perm in permissions() {
            let title = NSTextField(labelWithString: perm.name)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.frame = NSRect(x: leftX, y: y, width: 150, height: 16)
            content.addSubview(title)

            let detail = NSTextField(labelWithString: perm.detail)
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            detail.frame = NSRect(x: leftX, y: y - 15, width: 200, height: 14)
            content.addSubview(detail)

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11, weight: .medium)
            status.alignment = .right
            status.frame = NSRect(x: leftX + 190, y: y, width: 110, height: 16)
            content.addSubview(status)

            let action = NSButton(title: "Request Access", target: self, action: #selector(permissionAction(_:)))
            action.bezelStyle = .rounded
            action.controlSize = .small
            action.font = .systemFont(ofSize: 10)
            action.tag = permissionRows.count
            action.frame = NSRect(x: w - 24 - 110, y: y - 4, width: 110, height: 22)
            content.addSubview(action)

            permissionRows.append(PermissionRow(statusLabel: status, actionButton: action, permission: perm))
            y -= 44
        }

        // --- Updates section ---
        let sep = NSBox(frame: NSRect(x: leftX, y: y - 4, width: w - 48, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)

        updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.frame = NSRect(x: leftX, y: y - 44, width: 160, height: 28)
        content.addSubview(updateButton)

        openReleaseButton = NSButton(title: "View Release", target: self, action: #selector(openLatestRelease))
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.frame = NSRect(x: leftX + 168, y: y - 44, width: 110, height: 28)
        openReleaseButton.isHidden = true
        content.addSubview(openReleaseButton)

        let reportButton = NSButton(title: "Report an Issue", target: self, action: #selector(reportIssue))
        reportButton.bezelStyle = .rounded
        reportButton.frame = NSRect(x: w - 24 - 140, y: y - 44, width: 140, height: 28)
        content.addSubview(reportButton)

        updateStatus = NSTextField(wrappingLabelWithString: "")
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.frame = NSRect(x: leftX, y: y - 80, width: w - 48, height: 30)
        content.addSubview(updateStatus)

        win.contentView = content
        win.center()
        window = win
        refreshStatuses()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status refresh

    private func refreshStatuses() {
        for row in permissionRows where row.permission.name != "Notifications" {
            apply(effectiveStatus(for: row.permission), to: row)
        }
        refreshNotificationStatus()
    }

    /// Updates a row's status text and its action button. The button label reflects the next
    /// useful step: "Request Access" until macOS knows the app (which also registers it in
    /// System Settings), then "Open Settings" once it's been asked but not granted.
    private func apply(_ status: Status, to row: PermissionRow) {
        let (t, c) = Self.text(for: status)
        row.statusLabel.stringValue = t
        row.statusLabel.textColor = c
        switch status {
        case .granted:
            row.actionButton.isHidden = true
        case .denied:
            row.actionButton.isHidden = false
            row.actionButton.title = "Open Settings"
        case .notDetermined, .unknown:
            row.actionButton.isHidden = false
            row.actionButton.title = "Request Access"
        }
    }

    private func refreshNotificationStatus() {
        guard let row = permissionRows.first(where: { $0.permission.name == "Notifications" }) else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .denied: status = .denied
            case .notDetermined: status = .notDetermined
            @unknown default: status = .unknown
            }
            DispatchQueue.main.async { self.apply(status, to: row) }
        }
    }

    // MARK: - Actions

    /// One button per permission. If macOS has never been asked, this fires the native request
    /// (showing the prompt and registering the app in System Settings). If it was already denied,
    /// the request is a no-op, so we open the relevant Settings pane instead — where the app now
    /// appears because it was requested earlier.
    @objc private func permissionAction(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < permissionRows.count else { return }
        let row = permissionRows[index]

        // Already asked and denied → jump straight to Settings (the app is listed there now).
        if case .denied = effectiveStatus(for: row.permission) {
            if let url = URL(string: row.permission.settingsURL) { NSWorkspace.shared.open(url) }
            return
        }

        sender.isEnabled = false
        markRequested(row.permission.name)
        row.permission.request { [weak self] in
            guard let self = self else { return }
            sender.isEnabled = true
            let now = self.effectiveStatus(for: row.permission)
            self.apply(now, to: row)
            // If it still isn't granted after asking (needs a manual toggle like Screen
            // Recording / Accessibility, or the user declined), open Settings to finish there.
            if case .denied = now, let url = URL(string: row.permission.settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func openLatestRelease() {
        let url = latestReleaseURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    @objc private func reportIssue() {
        if let url = URL(string: "https://github.com/\(Self.repo)/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        updateButton.isEnabled = false
        openReleaseButton.isHidden = true
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.stringValue = "Checking GitHub for the latest release…"

        let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updateButton.isEnabled = true

                if let error = error {
                    self.updateStatus.textColor = .systemRed
                    self.updateStatus.stringValue = "Couldn't check for updates: \(error.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    self.updateStatus.stringValue = "No published releases yet on GitHub."
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.updateStatus.textColor = .systemRed
                    self.updateStatus.stringValue = "Couldn't read the release info from GitHub."
                    return
                }

                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if let page = json["html_url"] as? String { self.latestReleaseURL = URL(string: page) }

                switch Self.compareVersions(latest, current) {
                case .orderedDescending:
                    self.updateStatus.textColor = .systemGreen
                    self.updateStatus.stringValue = "Update available: \(latest) (you have \(current)). "
                        + "Update with: git pull && ./build-app.sh release"
                    self.openReleaseButton.isHidden = false
                default:
                    self.updateStatus.textColor = .secondaryLabelColor
                    self.updateStatus.stringValue = "You're up to date (\(current))."
                }
            }
        }.resume()
    }

    /// Numeric dotted-version comparison (e.g. "3.10.0" > "3.9.1"). Non-numeric parts sort as 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    func windowWillClose(_ notification: Notification) { /* keep instance for reuse */ }
}
