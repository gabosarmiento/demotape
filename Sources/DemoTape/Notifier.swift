import Foundation
import AppKit
import UserNotifications

/// Local notifications via UserNotifications. Asks once at launch, posts a fun "cooking"
/// notification when rendering starts, and a "ready" notification with a Reveal-in-Finder
/// action when it finishes. Shows even when DemoTape is in the foreground.
@available(macOS 12.3, *)
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var lastReadyURL: URL?
    private let readyCategory = "demotape.ready"
    private let revealAction = "demotape.reveal"

    private let cookingPhrases = [
        "Cooking your DemoTape…",
        "Rolling the tape…",
        "Adding the zooms and polish…",
        "Rendering the good stuff…",
        "Smoothing the cursor, framing it up…",
        "Making it look effortless…"
    ]

    /// Call once at launch (only meaningful inside the bundled .app).
    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // avoid crash if unbundled
        center.delegate = self
        let reveal = UNNotificationAction(identifier: revealAction, title: "Reveal in Finder",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: readyCategory, actions: [reveal],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        // Ask only when the decision hasn't been made yet; otherwise trust the LIVE status so the
        // `authorized` flag can't go stale (it previously only ever reflected a fresh prompt).
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.authorized = true
            case .notDetermined:
                self?.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    self?.authorized = granted
                }
            default:
                self?.authorized = false
            }
        }
    }

    /// Refreshes the cached authorization from the system (e.g. after the user flips it in
    /// System Settings while the app is running).
    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            self?.authorized = (settings.authorizationStatus == .authorized
                                || settings.authorizationStatus == .provisional)
        }
    }

    func renderStarted() {
        guard authorized else { return }
        post(title: "DemoTape", body: cookingPhrases.randomElement() ?? "Cooking your DemoTape…",
             category: nil)
    }

    /// Avatar generation is a longer (cloud) job — reassure the user it's working.
    func avatarStarted() {
        guard authorized else { return }
        post(title: "Generating your avatar presenter…",
             body: "This runs on HeyGen and takes a few minutes. You can keep working.", category: nil)
    }

    @discardableResult
    func avatarReady(url: URL) -> Bool {
        guard authorized else { return false }
        lastReadyURL = url
        post(title: "Your avatar presenter is ready 🎬", body: url.lastPathComponent, category: readyCategory)
        return true
    }

    /// Posts the "ready" notification (with a Reveal action). Returns false if notifications
    /// aren't authorized, so the caller can fall back to an alert.
    @discardableResult
    func renderFinished(url: URL) -> Bool {
        guard authorized else { return false }
        lastReadyURL = url
        post(title: "Your DemoTape is ready 🎬", body: url.lastPathComponent, category: readyCategory)
        return true
    }

    private func post(title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show even when the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // Reveal in Finder when the action (or the notification itself) is tapped.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        if let url = lastReadyURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        handler()
    }
}
